// Brain service: the rules above the filesystem and the search CLI.
//
//  - the area policy is the CLI's policy.json, reloaded when it changes;
//  - reads, listings and search results are limited to the allowed areas
//    (the policy's default areas plus whatever the request names explicitly);
//  - a create runs the documented preconditions, journals its intent, then
//    creates the file with O_EXCL (there is no overwrite path);
//  - a search is delegated to `laa-brain`, and results are filtered again here
//    so a policy mismatch between the CLI and the Bridge cannot widen access.

import { createHash } from 'node:crypto';
import { statSync } from 'node:fs';
import { badRequest, BridgeError } from '../errors.mjs';
import { createJournal } from './journal.mjs';
import { defaultAreas, loadPolicy, resolveAreas, zoneOf } from './policy.mjs';
import { brainSearchAdapter } from './search.mjs';
import { createBrainVault, hashBuffer, parseVaultPath, pathFromId } from './vault.mjs';

const MAX_QUERY_CHARS = 300;

function failClosed(name) {
  return () => {
    throw new BridgeError(503, 'brain_gates_unavailable',
      `the ${name} precondition is not configured; nothing was created`, { retryable: true });
  };
}

export function createBrainService({
  vaultRoot,
  policyFile,
  searchBin,
  createPrefixes = ['Inbox/'],
  journalFile = null,
  search = null,
  gates = {},
  now = () => Date.now(),
  policyLoader = loadPolicy,
} = {}) {
  let cache = null;

  function policy() {
    let info;
    try {
      info = statSync(policyFile);
    } catch {
      throw new BridgeError(503, 'brain_policy_unavailable',
        'the Brain area policy is not readable', { retryable: true });
    }
    if (!cache || cache.mtimeMs !== info.mtimeMs || cache.size !== info.size) {
      try {
        cache = { mtimeMs: info.mtimeMs, size: info.size, policy: policyLoader(policyFile) };
      } catch (err) {
        throw new BridgeError(503, 'brain_policy_unavailable',
          err?.message ?? 'the Brain area policy is not readable', { retryable: true });
      }
    }
    return cache.policy;
  }

  function vault() {
    return createBrainVault({ root: vaultRoot, policy: policy(), createPrefixes });
  }

  const journal = journalFile ? createJournal({ file: journalFile, now }) : null;
  const runSearch = search ?? brainSearchAdapter({ bin: searchBin });
  const checkGit = gates.git ?? failClosed('git');
  const checkDisk = gates.disk ?? failClosed('disk');
  const checkSyncthing = gates.sync ?? failClosed('syncthing');

  function areasFor(requested = []) {
    const resolved = resolveAreas(policy(), requested);
    if (resolved.unknown.length > 0) {
      throw badRequest('area_unknown',
        `unknown area: ${resolved.unknown.join(', ')} (allowed: ${resolved.optional.join(', ')})`);
    }
    return resolved;
  }

  function assertArea(rel, allowed) {
    const area = zoneOf(policy(), rel);
    if (!allowed.includes(area.zone)) throw new BridgeError(404, 'not_found', `note ${rel} is not in an allowed area`);
    return area;
  }

  return {
    policyFile,
    vaultRoot,

    list({ areas = [], limit, offset }) {
      const resolved = areasFor(areas);
      const items = vault().list({ allowedAreas: resolved.allowed });
      const page = items.slice(offset, offset + limit);
      return {
        items: page,
        total: items.length,
        nextCursor: offset + limit < items.length ? offset + limit : null,
        areas: resolved.allowed,
        optionalAreas: resolved.optional,
      };
    },

    read({ id, areas = [] }) {
      const resolved = areasFor(areas);
      const path = pathFromId(id);
      assertArea(path, resolved.allowed);
      const entry = vault().read({ path, allowedAreas: resolved.allowed });
      return { ...entry, etag: entry.contentHash };
    },

    async search({ query, k, areas = [], adopted = false, rerank = false }) {
      const text = typeof query === 'string' ? query.trim() : '';
      if (text.length === 0 || text.length > MAX_QUERY_CHARS) {
        throw badRequest('query_invalid', `q must be 1-${MAX_QUERY_CHARS} characters`);
      }
      const resolved = areasFor(areas);
      const defaults = defaultAreas(policy());
      const result = await runSearch({
        query: text,
        k,
        // Only the areas the request had to ask for; the CLI includes its own
        // defaults and validates the names again.
        areas: resolved.allowed.filter((area) => !defaults.includes(area)),
        adopted,
        rerank,
      });
      const allowed = resolved.allowed;
      const results = (result.results ?? [])
        .filter((hit) => typeof hit?.path === 'string')
        .map((hit) => ({ ...hit, path: hit.path.normalize('NFC') }))
        .filter((hit) => allowed.includes(zoneOf(policy(), hit.path).zone))
        .map((hit) => ({
          path: hit.path,
          section: hit.section ?? '',
          lines: Array.isArray(hit.lines) ? hit.lines : null,
          zone: hit.zone ?? zoneOf(policy(), hit.path).zone,
          status: hit.status ?? null,
          checked: hit.checked ?? null,
          relevance: typeof hit.p === 'number' ? hit.p : null,
          relevanceStatus: hit.relevance_status ?? 'unjudged',
          text: typeof hit.text === 'string' ? hit.text.slice(0, 4000) : '',
        }));
      return {
        query: result.query ?? text,
        found: Boolean(result.found) && results.length > 0,
        matchBasis: result.match_basis ?? 'unknown',
        areas: allowed,
        optionalAreas: resolved.optional,
        rerank,
        results,
        nextCursor: null,
      };
    },

    // The dependency states BRAIN-WRITE §5 wants observable, without touching
    // the shared /v1/health envelope.
    async gates() {
      const report = { vaultRoot, policyFile, defaultAreas: defaultAreas(policy()).sort() };
      try {
        report.vault = { available: statSync(vaultRoot).isDirectory() };
      } catch {
        report.vault = { available: false };
      }
      for (const [name, check] of [['git', checkGit], ['sync', checkSyncthing], ['disk', checkDisk]]) {
        try {
          report[name] = { ok: true, ...(await check()) };
        } catch (err) {
          report[name] = { ok: false, code: err?.code ?? 'unknown', message: err?.message ?? 'unavailable' };
        }
      }
      return report;
    },

    async create({ device, requestId, path, content, onConflict }) {
      const rel = parseVaultPath(path);
      if (typeof content !== 'string') throw badRequest('payload_invalid', 'content must be a string');

      // Preconditions before anything is written (BRAIN-WRITE §4-2, §5).
      checkDisk();
      await checkGit();
      await checkSyncthing();

      const contentHash = hashBuffer(Buffer.from(content, 'utf8'));
      if (!journal) {
        throw new BridgeError(503, 'brain_journal_unavailable',
          'the Brain create journal is not configured; nothing was created', { retryable: true });
      }
      const audit = {
        requestId,
        deviceId: device?.id ?? null,
        path: rel,
        contentHash,
        size: Buffer.byteLength(content, 'utf8'),
      };
      journal.intent(audit);

      let created;
      try {
        created = vault().create({ path: rel, content, onConflict });
      } catch (err) {
        journal.close({ ...audit, phase: 'aborted', code: err?.code ?? 'unknown' });
        throw err;
      }
      const closed = journal.close({
        ...audit,
        phase: 'committed',
        path: created.path,
        contentHash: created.contentHash,
        size: created.size,
      });
      if (!closed) {
        throw new BridgeError(500, 'brain_journal_incomplete',
          `note ${created.path} was created but the journal record could not be completed`);
      }
      return created;
    },
  };
}
