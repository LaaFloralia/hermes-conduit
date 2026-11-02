// /v1/skills: the installed skills, as names and descriptions only.

import assert from 'node:assert/strict';
import test from 'node:test';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describeSkill, unregisteredSkills, skillMetadata } from '../src/routes/skill-metadata.mjs';
import { parseFrontmatter } from '../src/routes/skills.mjs';
import { startBridge } from './helpers.mjs';

function workspace() {
  const dir = mkdtempSync(join(tmpdir(), 'laa-skills-test-'));
  return {
    dir,
    root(name) {
      const path = join(dir, name);
      mkdirSync(path, { recursive: true });
      return path;
    },
    skill(root, rel, frontmatter, body = '# body\nsecret text\n') {
      const path = join(root, rel);
      mkdirSync(path, { recursive: true });
      writeFileSync(join(path, 'SKILL.md'), `---\n${frontmatter}\n---\n\n${body}`);
      return path;
    },
    cleanup() {
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

async function withBridge(roots, brainRoots, run) {
  const bridge = await startBridge({ skills: { roots, brainRoots } });
  try {
    const token = await bridge.token(['sessions:read']);
    return await run({ bridge, token });
  } finally {
    await bridge.close();
  }
}

test('lists the Claude and Hermes skills from frontmatter only', async () => {
  const files = workspace();
  try {
    const claude = files.root('claude');
    const hermes = files.root('hermes');
    files.skill(claude, 'cf-cli', 'name: cf-cli\ndescription: Cloudflareの標準');
    files.skill(claude, 'docx', 'name: docx\ndescription: Word文書');
    files.skill(hermes, 'ytsummary', 'name: ytsummary\ndescription: YouTube要約');
    // Hermes keeps categories one level down.
    files.skill(hermes, 'software-development/github', 'name: github\ndescription: GitHub操作');
    // Not skills: a dot directory, a folder without SKILL.md, a category folder.
    files.skill(claude, '.hidden', 'name: hidden\ndescription: 見えない');
    mkdirSync(join(claude, 'empty'), { recursive: true });
    mkdirSync(join(hermes, 'apple'), { recursive: true });
    writeFileSync(join(hermes, 'apple', 'DESCRIPTION.md'), '---\nname: apple\ndescription: カテゴリ\n---\n');

    await withBridge(
      [{ source: 'Claude', dir: claude }, { source: 'Hermes', dir: hermes }],
      [join(files.dir, 'Brain')],
      async ({ bridge, token }) => {
        const response = await bridge.request('/v1/skills', { token });
        assert.equal(response.status, 200);
        assert.equal(response.body.data.nextCursor, null);
        assert.deepEqual(response.body.data.items.map(({ category, summary, detail, metadataKnown, ...raw }) => raw), [
          { id: 'claude:cf-cli', name: 'cf-cli', description: 'Cloudflareの標準', source: 'Claude' },
          { id: 'claude:docx', name: 'docx', description: 'Word文書', source: 'Claude' },
          { id: 'hermes:software-development/github', name: 'github', description: 'GitHub操作', source: 'Hermes' },
          { id: 'hermes:ytsummary', name: 'ytsummary', description: 'YouTube要約', source: 'Hermes' },
        ]);
        // The body is never part of the answer.
        assert.doesNotMatch(JSON.stringify(response.body), /secret text/);
      },
    );
  } finally {
    files.cleanup();
  }
});

test('the skills HTTP response includes known category and Japanese metadata', async () => {
  const files = workspace();
  try {
    const root = files.root('claude');
    files.skill(root, 'cf-cli', 'name: cf-cli\ndescription: Cloudflareの標準');
    await withBridge([{ source: 'Claude', dir: root }], [], async ({ bridge, token }) => {
      const response = await bridge.request('/v1/skills', { token });
      assert.equal(response.status, 200);
      const [skill] = response.body.data.items;
      assert.equal(skill.name, 'cf-cli');
      assert.equal(skill.category, '開発・運用');
      assert.equal(skill.metadataKnown, true);
      assert.equal(skill.summary, 'Cloudflareを既存のCLIで操作する');
      assert.equal(skill.detail, 'Worker、D1、R2、DNSなどを確認・変更し、配信後の状態を検証します。');
    });
  } finally {
    files.cleanup();
  }
});

test('a missing folder is an empty list, a real read failure is a 503', async () => {
  const files = workspace();
  try {
    const claude = files.root('claude');
    files.skill(claude, 'one', 'name: one\ndescription: 一つ');
    const missing = join(files.dir, 'no-hermes');

    await withBridge(
      [{ source: 'Claude', dir: claude }, { source: 'Hermes', dir: missing }],
      [],
      async ({ bridge, token }) => {
        const response = await bridge.request('/v1/skills', { token });
        assert.equal(response.status, 200);
        assert.deepEqual(response.body.data.items.map((item) => item.id), ['claude:one']);
      },
    );

    await withBridge(
      [{ source: 'Claude', dir: join(files.dir, 'nothing') }, { source: 'Hermes', dir: missing }],
      [],
      async ({ bridge, token }) => {
        const response = await bridge.request('/v1/skills', { token });
        assert.equal(response.status, 200);
        assert.deepEqual(response.body.data.items.map(({ category, summary, detail, metadataKnown, ...raw }) => raw), []);
      },
    );

    // A SKILL.md that exists but cannot be read must not look like "no skills".
    const blocked = files.skill(claude, 'blocked', 'name: blocked\ndescription: 読めない');
    chmodSync(join(blocked, 'SKILL.md'), 0o000);
    try {
      await withBridge([{ source: 'Claude', dir: claude }], [], async ({ bridge, token }) => {
        const response = await bridge.request('/v1/skills', { token });
        assert.equal(response.status, 503);
        assert.equal(response.body.error.code, 'skills_unreadable');
        assert.doesNotMatch(JSON.stringify(response.body), /blocked|SKILL\.md/);
      });
    } finally {
      chmodSync(join(blocked, 'SKILL.md'), 0o600);
    }

    // A category folder that cannot be listed is the same failure.
    const category = join(claude, 'category');
    mkdirSync(category, { recursive: true });
    chmodSync(category, 0o000);
    try {
      await withBridge([{ source: 'Claude', dir: claude }], [], async ({ bridge, token }) => {
        const response = await bridge.request('/v1/skills', { token });
        assert.equal(response.status, 503);
        assert.equal(response.body.error.code, 'skills_unreadable');
      });
    } finally {
      chmodSync(category, 0o700);
    }
  } finally {
    files.cleanup();
  }
});

test('a linked skill is listed, a link into the Brain is not opened', async () => {
  const files = workspace();
  try {
    const claude = files.root('claude');
    const shared = files.root('agents');
    files.skill(shared, 'cf-cli', 'name: cf-cli\ndescription: 共有skill');
    symlinkSync(join(shared, 'cf-cli'), join(claude, 'cf-cli'));

    const brain = files.root('Brain');
    files.skill(brain, 'Context', 'name: 社長の文脈\ndescription: Brainの内部');
    symlinkSync(join(brain, 'Context'), join(claude, 'leak'));

    await withBridge(
      [{ source: 'Claude', dir: claude }],
      [brain],
      async ({ bridge, token }) => {
        const response = await bridge.request('/v1/skills', { token });
        assert.equal(response.status, 200);
        assert.deepEqual(response.body.data.items.map(({ category, summary, detail, metadataKnown, ...raw }) => raw), [
          { id: 'claude:cf-cli', name: 'cf-cli', description: '共有skill', source: 'Claude' },
        ]);
        assert.doesNotMatch(JSON.stringify(response.body), /社長の文脈/);
      },
    );
  } finally {
    files.cleanup();
  }
});

test('frontmatter parsing keeps the two fields and survives folded values', () => {
  assert.deepEqual(parseFrontmatter('---\nname: a\ndescription: b\n---\nbody'), { name: 'a', description: 'b' });
  assert.deepEqual(parseFrontmatter('---\nname: "quoted"\ndescription: >\n  長い\n  説明\n---\n'), {
    name: 'quoted',
    description: '長い 説明',
  });
  assert.deepEqual(parseFrontmatter('---\nname: a\n---\n'), { name: 'a', description: '' });
  // A file without frontmatter is not a skill, and neither is an unclosed block.
  assert.equal(parseFrontmatter('# title\n'), null);
  assert.equal(parseFrontmatter('---\nname: a\nbody\n'), null);
  assert.equal(parseFrontmatter(''), null);
});

test('long descriptions are clipped and the count is bounded', async () => {
  const files = workspace();
  try {
    const claude = files.root('claude');
    files.skill(claude, 'long', `name: long\ndescription: ${'x'.repeat(600)}`);
    for (let index = 0; index < 4; index += 1) {
      files.skill(claude, `skill-${index}`, `name: skill-${index}\ndescription: d`);
    }
    // A file larger than the read limit whose frontmatter closes early is fine.
    files.skill(claude, 'huge', 'name: huge\ndescription: 大きい', 'y'.repeat(70 * 1024));

    await withBridge([{ source: 'Claude', dir: claude }], [], async ({ bridge, token }) => {
      const response = await bridge.request('/v1/skills', { token });
      assert.equal(response.status, 200);
      const long = response.body.data.items.find((item) => item.id === 'claude:long');
      assert.equal(long.description.length, 500);
      assert.equal(response.body.data.items.length, 6);
    });

    const limited = await startBridge({ skills: { roots: [{ source: 'Claude', dir: claude }], brainRoots: [], maxSkills: 2 } });
    try {
      const token = await limited.token(['sessions:read']);
      const response = await limited.request('/v1/skills', { token });
      assert.equal(response.body.data.items.length, 2);
      assert.deepEqual(response.body.data.items.map((item) => item.id), ['claude:huge', 'claude:long']);
    } finally {
      await limited.close();
    }
  } finally {
    files.cleanup();
  }
});

test('reading skills needs sessions:read', async () => {
  const files = workspace();
  try {
    const claude = files.root('claude');
    files.skill(claude, 'one', 'name: one\ndescription: 一つ');
    const bridge = await startBridge({ skills: { roots: [{ source: 'Claude', dir: claude }], brainRoots: [] } });
    try {
      const denied = await bridge.token(['tasks:read']);
      const response = await bridge.request('/v1/skills', { token: denied });
      assert.equal(response.status, 403);
      assert.equal(response.body.error.code, 'insufficient_scope');

      const anonymous = await bridge.request('/v1/skills');
      assert.equal(anonymous.status, 401);
    } finally {
      await bridge.close();
    }
  } finally {
    files.cleanup();
  }
});

test('unknown skills preserve the original description, and coverage identifies newly installed names', () => {
  assert.deepEqual(describeSkill('not-registered', 'Original description'), {
    category: 'その他', summary: 'Original description', detail: 'Original description', metadataKnown: false,
  });
  assert.deepEqual(unregisteredSkills([{ name: 'cf-cli' }, { name: 'new-skill' }, { name: 'new-skill' }]), ['new-skill']);
  for (const [name, value] of Object.entries(skillMetadata)) {
    assert.ok(value.category && value.summary && value.detail, name);
    assert.match(value.summary, /[ぁ-んァ-ン一-龠]/, name);
    assert.ok(value.summary.length <= 60 && value.detail.length <= 200, name);
  }
});
