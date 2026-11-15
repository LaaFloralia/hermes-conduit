import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { appendFileSync, linkSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, truncateSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { daemonAdapter, daemonSessionID } from '../src/sessions/daemon.mjs';
import { createSessionService } from '../src/sessions/service.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { sessionImageStore } from '../src/sessions/images.mjs';
import { inspectLocalImage, readLocalImage, settleLocalImages, splitLocalImages } from '../src/sessions/local-images.mjs';
import { ownerPathAllowed, readOwnerFile } from '../src/sessions/owner-files.mjs';
import { startBridge } from './helpers.mjs';

const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);

function homeFixture(t) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'owner-files-')));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const home = join(dir, 'home'), outside = join(dir, 'outside');
  mkdirSync(join(home, 'work', 'x'), { recursive: true });
  mkdirSync(outside);
  const put = (relative, data) => {
    const path = join(home, relative);
    mkdirSync(join(path, '..'), { recursive: true });
    writeFileSync(path, data);
    return path;
  };
  return { dir, home, outside, put };
}

function daemonFixture() {
  const rows = [{ id: 'parent', title: '親', provider: 'codex', model: 'gpt-6.1-sol', createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-02T00:00:00Z', status: 'idle', labels: {} }];
  const client = { close: async () => {}, fetchAgent: async ({ agentId }) => ({ agent: rows.find((a) => a.id === agentId) }),
    getLastServerInfoMessage: () => ({ features: {} }),
    fetchWorkspaces: async () => ({ entries: [], pageInfo: { nextCursor: null } }),
    fetchAgents: async () => ({ entries: rows.map((agent) => ({ agent })), pageInfo: { nextCursor: null } }) };
  return { connect: async () => client };
}

test('an owner file is read from one checked descriptor; secrets, links out of home and odd files are not', (t) => {
  const { home, outside, put } = homeFixture(t);
  const read = (path, options = {}) => readOwnerFile(path, { home, ...options });
  const result = put('work/x/RESULT.md', '# 結果\n');
  const file = read(result);
  assert.equal(file.mimeType, 'text/markdown');
  assert.equal(file.name, 'RESULT.md');
  assert.equal(file.data.toString(), '# 結果\n');
  assert.equal(read(put('work/x/chart.html', '<p>x</p>')).mimeType, 'text/html');
  assert.equal(read(put('work/x/a.pdf', '%PDF-1.7')).mimeType, 'application/pdf');
  assert.equal(read(put('.local/state/laa-muse/shot.png', png)).mimeType, 'image/png', 'a tool state picture is an ordinary file');
  assert.equal(read(put('work/x/empty.txt', '')).size, 0);

  // Places and names where secrets live.
  for (const relative of [
    '.ssh/id_ed25519', '.ssh/config', '.config/op/config', '.config/laa/mac-release.env.tpl', '.gnupg/key.txt', '.aws/config',
    'Library/Keychains/login.keychain-db', 'library/Cookies/x.txt', '.local/state/laa-bridge/state.json',
    'work/x/.env', 'work/x/.env.local', 'work/x/prod.env', 'work/x/server.pem', 'work/x/id_rsa', 'work/x/credentials.json',
    '.claude/.credentials.json', '.codex/auth.json', 'work/x/secrets.md', 'dev/repo/.git/config', 'work/.SSH/known.txt',
  ]) {
    assert.equal(read(put(relative, 'secret')), null, relative);
  }
  // Library is denied only from home: a project's own folder of that name is not.
  assert.equal(read(put('dev/app/Library/notes.md', 'ok')).size, 2);

  // Outside home, relative, traversal and malformed paths.
  writeFileSync(join(outside, 'a.md'), 'outside');
  assert.equal(read(join(outside, 'a.md')), null);
  assert.equal(read(join(home, '..', 'outside', 'a.md')), null);
  assert.equal(read('work/x/RESULT.md'), null);
  assert.equal(read(`${result}\0`), null);
  assert.equal(read(''), null);
  assert.equal(read(home), null);
  assert.equal(read(join(home, 'work')), null, 'a folder is not a file');
  assert.equal(read('/etc/hosts'), null);

  // Symlinks: a final link is never followed, a folder link may not leave home
  // or reach a denied folder; one that stays inside home to a permitted folder is
  // read under its real name.
  symlinkSync(result, join(home, 'work', 'link.md'));
  assert.equal(read(join(home, 'work', 'link.md')), null);
  symlinkSync(outside, join(home, 'work', 'out'));
  assert.equal(read(join(home, 'work', 'out', 'a.md')), null);
  symlinkSync(join(home, '.ssh'), join(home, 'work', 'peek'));
  assert.equal(read(join(home, 'work', 'peek', 'config')), null);
  symlinkSync(join(home, 'work', 'x'), join(home, 'alias'));
  assert.equal(read(join(home, 'alias', 'RESULT.md')).path, result);

  // A hard link can name a secret from a permitted folder.
  linkSync(join(home, '.ssh', 'config'), join(home, 'work', 'hard.txt'));
  assert.equal(read(join(home, 'work', 'hard.txt')), null);
  // A FIFO neither hangs nor reads.
  execFileSync('mkfifo', [join(home, 'work', 'pipe.txt')]);
  assert.equal(read(join(home, 'work', 'pipe.txt')), null);

  // Size: the limit, and a file that changes while it is read.
  const big = put('work/x/big.bin', 'x'); truncateSync(big, 17);
  assert.equal(read(big, { maxBytes: 16 }), null);
  assert.equal(read(result, { beforeRead: () => appendFileSync(result, 'more') }), null);
  assert.equal(read(result, { beforeRead: () => truncateSync(result, 1) }), null);

  assert.equal(ownerPathAllowed(join(home, 'work', 'a.md'), home), true);
  assert.equal(ownerPathAllowed(home, home), false);
  assert.equal(ownerPathAllowed(`${home}x/a.md`, home), false, 'a sibling folder sharing the prefix is outside');
});

test("a reply's pictures under home become the session's images; a preview of a picture too", async (t) => {
  const { dir, home, put } = homeFixture(t);
  const tempRoot = realpathSync(tmpdir());
  const picture = put('work/x/候補1.png', png);
  const denied = put('.ssh/look.png', png);
  const notImage = put('work/x/fake.png', 'not a picture');
  const inspect = (path) => inspectLocalImage(path, { tempRoot, home });
  assert.equal(inspect(picture)?.mimeType, 'image/png');
  assert.equal(inspect(denied), null);
  assert.equal(inspect(notImage), null);
  assert.equal(inspectLocalImage(picture, { tempRoot }), null, 'the real home is another folder');

  const split = splitLocalImages([
    '画像はこの会話に直接出します。',
    `![3案の比較](${picture})`,
    `![全6枚](file://${encodeURI(picture)})`,
    `::preview{file="${picture}"}`,
    `::preview{file="${join(home, 'work', 'x', 'chart.html')}"}`,
    `![角括弧](<${picture}>)`,
    '```', `![例](${picture})`, '```',
    `> ![引用](${picture})`,
    '![web](https://example.com/a.png) std::preview{file="/Users/laa/a.png"}',
  ].join('\n'));
  assert.deepEqual(split.paths, [picture, picture, picture, picture]);
  assert.equal(split.text.split('\n')[4], `::preview{file="${join(home, 'work', 'x', 'chart.html')}"}`, 'an HTML preview stays for the app');
  assert.ok(split.text.includes('```\n![例]'), 'fenced code is an example');
  assert.ok(split.text.includes('> ![引用]'), 'a quoted line is an example');
  assert.ok(split.text.endsWith('![web](https://example.com/a.png) std::preview{file="/Users/laa/a.png"}'));
  assert.equal(settleLocalImages(split.text, split.paths, ['a', 'b', 'c', null]).split('\n')[5], '（画像を表示できません）');

  const images = sessionImageStore(join(dir, 'images'), { inspect, inspectTtlMs: 0, readLocal: (path) => readLocalImage(path, { tempRoot, home }) });
  const text = splitLocalImages(`できました。\n\n![候補](${picture})\n\n![秘密](${denied})`);
  const service = createSessionService({
    sessionStore: createSessionStore({ file: join(dir, 'sessions.json') }), daemon: daemonAdapter({ connect: daemonFixture().connect, now: () => 1000 }),
    adapter: {}, findWorkspace: async () => null, notify: async () => {},
    images, history: async () => ({ compacting: false, items: [{ id: 'm1', role: 'assistant', text: text.text, localImages: text.paths }] }),
  });
  await service.syncDaemon();
  const id = daemonSessionID('parent');
  const { items } = await service.conversation(id);
  assert.equal(items[0].images.length, 1);
  assert.equal(items[0].text, 'できました。\n\n\n\n（画像を表示できません）');
  const image = service.image(id, items[0].images[0]);
  assert.deepEqual(Buffer.from(image.data, 'base64'), png);
});

test('the files route serves a session its owner files with sessions:read and refuses the rest', async (t) => {
  const { home, put } = homeFixture(t);
  const result = put('work/x/RESULT.md', '# 結果\n');
  const secret = put('.ssh/config', 'Host *');
  const bridge = await startBridge({ sessions: {
    daemon: daemonAdapter({ connect: daemonFixture().connect, now: () => 1000 }),
    notify: async () => {},
    readOwner: (path) => readOwnerFile(path, { home }),
  } });
  t.after(() => bridge.close());
  const token = await bridge.token(['sessions:read']);
  await bridge.request('/v1/sessions', { token });
  const id = daemonSessionID('parent');
  const url = (path) => `/v1/sessions/${id}/files?path=${encodeURIComponent(path)}`;
  const ok = await bridge.request(url(result), { token });
  assert.equal(ok.status, 200);
  assert.deepEqual({ ...ok.body.data, data: Buffer.from(ok.body.data.data, 'base64').toString() },
    { name: 'RESULT.md', mimeType: 'text/markdown', size: 9, data: '# 結果\n' });
  assert.equal((await bridge.request(url(secret), { token })).status, 404);
  assert.equal((await bridge.request(url('/etc/hosts'), { token })).status, 404);
  assert.equal((await bridge.request(`/v1/sessions/${id}/files`, { token })).status, 404);
  assert.equal((await bridge.request(url(result))).status, 401);
  assert.equal((await bridge.request(`/v1/sessions/ses_${'0'.repeat(16)}/files?path=${encodeURIComponent(result)}`, { token })).status, 404);
  const noScope = await bridge.token(['tasks:read']);
  assert.equal((await bridge.request(url(result), { token: noScope })).status, 403);
});
