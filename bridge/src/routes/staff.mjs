import { constants } from 'node:fs';
import { access, readFile, realpath, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { lanePath } from '../lane/guard.mjs';

const DEFAULT_ROSTER = '/Users/laa/hq/roles/roster.yaml';
const SIBLING_ROSTER = fileURLToPath(new URL('../../../../hq/roles/roster.yaml', import.meta.url));
const nonEmpty = (word) => typeof word === 'string' && word.trim().length > 0;

function parseThinking(text) {
  try {
    const thinking = JSON.parse(text);
    if (nonEmpty(thinking?.base) && Array.isArray(thinking.alt) && thinking.alt.every(nonEmpty)) {
      return { base: thinking.base, alt: thinking.alt };
    }
  } catch { /* A malformed field does not hide the role. */ }
  return undefined;
}

// Read only the fixed roster schema: two-space role IDs, four-space fields,
// and one-line JSON for thinking. Other YAML fields are not public.
function projectStaff(text) {
  const staff = [];
  let inRoles = false;
  let role;
  for (const line of text.split(/\r?\n/)) {
    if (!inRoles) {
      inRoles = /^roles:[ \t]*(?:#.*)?$/.test(line);
      continue;
    }
    if (/^[^\s#]/.test(line)) break;
    const id = /^  - id: ([a-z][a-z0-9_-]*)[ \t]*(?:#.*)?$/.exec(line)?.[1];
    if (line.startsWith('  - ')) {
      role = id ? { id, profile: `laa-${id}`, name: id } : undefined;
      if (role) staff.push(role);
    } else if (role) {
      const name = /^    name:[ \t]*([^#]+?)[ \t]*(?:#.*)?$/.exec(line)?.[1]?.trim();
      if (name) role.name = name;
      if (line.startsWith('    thinking:')) {
        const thinking = parseThinking(line.slice('    thinking:'.length));
        if (thinking) role.thinking = thinking;
      }
    }
  }
  return staff;
}

export function staffRoutes({ path = process.env.LAA_ROSTER_PATH, log, lane } = {}) {
  // A default lab run must not read the live HQ file. A test can explicitly
  // pass the sibling HQ worktree roster or an in-lane fixture.
  const source = path || (lane ? join(lane.root, 'roster.yaml') : DEFAULT_ROSTER);
  let cached;
  let inFlight;
  async function read() {
    try {
      // The explicit sibling path is a read-only worktree input, not an adapter.
      // Verify it is not a symlink into live state; all other lab inputs stay in the lane.
      let file = source;
      if (lane && !(source === SIBLING_ROSTER && source !== DEFAULT_ROSTER && await realpath(source) === source)) {
        file = lanePath(lane.root, source, 'LAA_ROSTER_PATH');
      }
      const info = await stat(file, { bigint: true });
      if (!info.isFile()) throw new Error('roster is not a regular file');
      if (cached?.mtime === info.mtimeNs) {
        // chmod does not change mtime; do not serve a now-unreadable source.
        await access(file, constants.R_OK);
      } else {
        cached = { mtime: info.mtimeNs, staff: projectStaff(await readFile(file, 'utf8')) };
      }
      return cached.staff;
    } catch {
      cached = undefined;
      log?.({ level: 'warn', event: 'staff_roster_unreadable' });
      return [];
    }
  }
  return [{ method: 'GET', path: '/v1/staff', auth: true, scope: 'sessions:read', handler: async () => {
    inFlight ??= read().finally(() => { inFlight = undefined; });
    return { status: 200, data: { staff: await inFlight } };
  } }];
}
