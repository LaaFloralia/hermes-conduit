// GET /v1/skills — the skills the Mac has installed, for the Work tab's list.
//
// Only the two frontmatter fields a list needs are read (`name`,
// `description`); the body of a SKILL.md is never returned, logged or kept.
// The folders are the agent skill directories the Mac already uses:
//
//   ~/.claude/skills/<skill>/SKILL.md          (source Claude)
//   ~/.hermes/skills/<skill>/SKILL.md          (source Hermes)
//   ~/.hermes/skills/<category>/<skill>/SKILL.md   (Hermes keeps categories)
//
// A skill directory is usually a symlink into ~/.agents/skills; that is a
// normal skill and is followed. A link that resolves inside the Brain vault is
// not: the Bridge must not read the Brain for a list, so those entries are
// skipped without being opened.
//
// A missing root is an empty list (a Mac without Hermes is normal). A real
// read failure is a 503: an empty list would say "you have no skills", which is
// a different and false answer.

import { open, readdir, realpath, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { describeSkill } from './skill-metadata.mjs';
import { BridgeError } from '../errors.mjs';
import { resolveBrainRoot } from '../config.mjs';

const SKILL_FILE = 'SKILL.md';
const MAX_SKILLS = 500;
const MAX_SKILL_BYTES = 64 * 1024;
const MAX_DEPTH = 2;
const DESCRIPTION_MAX = 500;

function defaultRoots(env = process.env) {
  return [
    { source: 'Claude', dir: env.LAA_BRIDGE_CLAUDE_SKILLS || join(homedir(), '.claude', 'skills') },
    { source: 'Hermes', dir: env.LAA_BRIDGE_HERMES_SKILLS || join(homedir(), '.hermes', 'skills') },
  ];
}

function defaultBrainRoots(env = process.env) {
  return [resolveBrainRoot(env), resolve(join(homedir(), 'brain'))];
}

function unreadable() {
  // The path is deliberately not included: it is a filesystem detail the client
  // cannot act on, and the message is logged by the pipeline anyway.
  return new BridgeError(503, 'skills_unreadable', 'the skill folders could not be read', { retryable: false });
}

function isUnder(path, roots) {
  const lower = path.toLowerCase();
  return roots.some((root) => {
    const prefix = root.toLowerCase();
    return lower === prefix || lower.startsWith(prefix.endsWith(sep) ? prefix : `${prefix}${sep}`);
  });
}

function unquote(value) {
  if (value.length >= 2) {
    const first = value[0];
    const last = value[value.length - 1];
    if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
      return value.slice(1, -1).trim();
    }
  }
  return value;
}

// Reads the YAML frontmatter block only: `key: value` lines plus indented
// continuations, which covers the `description: >` form. Anything else in the
// file is ignored.
export function parseFrontmatter(text) {
  const lines = text.split(/\r?\n/);
  if (lines.length === 0 || lines[0].trim() !== '---') return null;
  let end = -1;
  for (let index = 1; index < lines.length; index += 1) {
    if (lines[index].trim() === '---') {
      end = index;
      break;
    }
  }
  if (end < 0) return null;

  const fields = {};
  let key = null;
  for (const line of lines.slice(1, end)) {
    const match = /^([A-Za-z0-9_-]+)\s*:\s*(.*)$/.exec(line);
    if (match) {
      key = match[1];
      const value = match[2].trim();
      fields[key] = /^[>|][+-]?$/.test(value) ? '' : unquote(value);
      continue;
    }
    if (key !== null && /^\s+\S/.test(line)) {
      const continued = line.trim();
      fields[key] = fields[key] === '' ? continued : `${fields[key]} ${continued}`;
    }
  }

  const name = typeof fields.name === 'string' ? fields.name.trim() : '';
  const description = typeof fields.description === 'string' ? fields.description.trim() : '';
  return { name, description };
}

async function readSkillFile(dir) {
  let handle;
  try {
    handle = await open(join(dir, SKILL_FILE), 'r');
  } catch (error) {
    if (error?.code === 'ENOENT' || error?.code === 'ENOTDIR' || error?.code === 'ELOOP') return null;
    throw unreadable();
  }
  try {
    const buffer = Buffer.alloc(MAX_SKILL_BYTES);
    const { bytesRead } = await handle.read(buffer, 0, MAX_SKILL_BYTES, 0);
    return buffer.subarray(0, bytesRead).toString('utf8');
  } catch {
    throw unreadable();
  } finally {
    await handle.close().catch(() => {});
  }
}

async function listDirectory(dir) {
  try {
    return await readdir(dir, { withFileTypes: true });
  } catch (error) {
    if (error?.code === 'ENOENT' || error?.code === 'ENOTDIR') return null;
    throw unreadable();
  }
}

function byName(a, b) {
  return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
}

export function createSkillIndex({
  roots = defaultRoots(),
  brainRoots = defaultBrainRoots(),
  maxSkills = MAX_SKILLS,
} = {}) {
  async function visit({ root, rel, name, depth, items, deny }) {
    const path = join(root.dir, rel);
    let real;
    try {
      real = await realpath(path);
    } catch (error) {
      if (error?.code === 'ENOENT' || error?.code === 'ELOOP' || error?.code === 'ENOTDIR') return;
      throw unreadable();
    }
    if (isUnder(real, deny)) return;
    let info;
    try {
      info = await stat(real);
    } catch (error) {
      if (error?.code === 'ENOENT' || error?.code === 'ELOOP') return;
      throw unreadable();
    }
    if (!info.isDirectory()) return;

    const text = await readSkillFile(real);
    if (text !== null) {
      const meta = parseFrontmatter(text);
      if (meta === null) return;
      const description = meta.description.length > DESCRIPTION_MAX
        ? meta.description.slice(0, DESCRIPTION_MAX)
        : meta.description;
      items.push({
        id: `${root.source.toLowerCase()}:${rel}`,
        name: meta.name === '' ? name : meta.name,
        description,
        source: root.source,
        ...describeSkill(meta.name === '' ? name : meta.name, description),
      });
      // A skill's own folders (references, scripts) are not more skills.
      return;
    }
    if (depth >= MAX_DEPTH) return;

    const entries = await listDirectory(real);
    if (!entries) return;
    for (const entry of entries.filter((item) => !item.name.startsWith('.')).sort(byName)) {
      if (items.length >= maxSkills) return;
      await visit({ root, rel: `${rel}/${entry.name}`, name: entry.name, depth: depth + 1, items, deny });
    }
  }

  return {
    async list() {
      // Compare real paths: on macOS /var is a link to /private/var, and the
      // configured vault path must match what realpath reports for a skill.
      const deny = await Promise.all(brainRoots.map(async (root) => {
        try {
          return await realpath(root);
        } catch {
          return root;
        }
      }));
      const items = [];
      for (const root of roots) {
        if (items.length >= maxSkills) break;
        const entries = await listDirectory(root.dir);
        if (!entries) continue;
        for (const entry of entries.filter((item) => !item.name.startsWith('.')).sort(byName)) {
          if (items.length >= maxSkills) break;
          await visit({ root, rel: entry.name, name: entry.name, depth: 1, items, deny });
        }
      }
      items.sort((a, b) => (a.source === b.source ? (a.id < b.id ? -1 : a.id > b.id ? 1 : 0) : (a.source < b.source ? -1 : 1)));
      return { items };
    },
  };
}

export function skillRoutes({ roots, brainRoots, maxSkills } = {}) {
  const index = createSkillIndex({ roots, brainRoots, maxSkills });

  async function list() {
    const outcome = await index.list();
    return { status: 200, data: { items: outcome.items, nextCursor: null } };
  }

  return [
    { method: 'GET', path: '/v1/skills', auth: true, scope: 'sessions:read', handler: list },
  ];
}
