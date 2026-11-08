// The short-number registry: one file next to state.json, written only by the
// Bridge server. A ref is an alias on top of an identity the source already
// owns (Linear issue id, session id, project id, routine id, skill name), so
// nothing here can rename or replace the object it points at.
//
// Allocation: a key that held a number before gets it back when the number is
// free (restore keeps its number). Otherwise the smallest free number wins,
// skipping numbers another key released within the last 24 hours so a stale
// chat message cannot silently point at a new object.
//
// Release happens only on a complete successful read of the kind's source, or
// on a Bridge-mediated archive/delete. A failed or paginated read never calls
// `observeComplete`, which is why this module has no partial-read entry point.

import { StateFileError } from '../routes/state-file.mjs';
import { createJsonFile } from '../routes/state-file.mjs';

export const REFS_SCHEMA = 1;
export const COOLDOWN_MS = 24 * 60 * 60 * 1000;
export const HISTORY_MS = 30 * 24 * 60 * 60 * 1000;
export const MAX_N = 99999;
export const KINDS = Object.freeze(['task', 'session', 'project', 'routine', 'skill']);
export const PREFIX = Object.freeze({ task: 'T', session: 'S', project: 'P', routine: 'R', skill: 'K' });
export const KIND_BY_PREFIX = Object.freeze({ T: 'task', S: 'session', P: 'project', R: 'routine', K: 'skill' });
const PREFIX_PATTERN = /^([TSPRK])0*([1-9][0-9]{0,4})$/;

export class RefInputError extends Error {
  constructor(message = 'ref must look like T12') {
    super(message);
    this.name = 'RefInputError';
    this.code = 'ref_invalid';
  }
}

// NFKC folds full-width letters and digits; spaces, `-` and `_` are spoken or
// typed as separators, so `Ｔ１２`, `t 12` and `T-12` all become T12.
export function normalizeRefInput(input) {
  if (typeof input !== 'string') return null;
  const compact = input.normalize('NFKC').trim().replace(/[\s_-]/g, '').toUpperCase();
  const match = PREFIX_PATTERN.exec(compact);
  if (!match) return null;
  const n = Number(match[2]);
  if (!Number.isInteger(n) || n < 1 || n > MAX_N) return null;
  const kind = KIND_BY_PREFIX[match[1]];
  return { ref: `${PREFIX[kind]}${n}`, kind, n };
}

export function requireRefInput(input) {
  const normalized = normalizeRefInput(input);
  if (!normalized) throw new RefInputError();
  return normalized;
}

function cleanTitle(raw) {
  if (typeof raw !== 'string') return '';
  return raw.trim().slice(0, 200);
}

function copy(value) {
  return structuredClone(value);
}

function parseIdentifierNumber(identifier) {
  const match = /(\d+)\s*$/.exec(typeof identifier === 'string' ? identifier : '');
  return match ? Number(match[1]) : Number.MAX_SAFE_INTEGER;
}

// Initial bulk assignment order (contract): oldest first per kind. Tasks use
// the Linear identifier's number so BUS-12 precedes BUS-130.
export function orderRefItems(kind, items) {
  const rows = items.map((item, index) => ({ item, index }));
  rows.sort((a, b) => {
    const x = a.item;
    const y = b.item;
    let primary = 0;
    if (kind === 'task') {
      primary = parseIdentifierNumber(x.external?.linear) - parseIdentifierNumber(y.external?.linear);
    } else if (kind === 'session' || kind === 'project') {
      primary = String(x.createdAt ?? '').localeCompare(String(y.createdAt ?? ''));
    }
    if (primary !== 0) return primary;
    const keyOrder = String(x.key).localeCompare(String(y.key));
    if (keyOrder !== 0) return keyOrder;
    return a.index - b.index;
  });
  return rows.map((row) => row.item);
}

export function createRefRegistry({ file, now = () => Date.now() }) {
  const state = createJsonFile({
    file,
    schema: REFS_SCHEMA,
    initial: () => ({ records: [], observedAt: { task: null, session: null, project: null, routine: null, skill: null } }),
  });

  function readDoc() {
    const doc = state.read();
    // A document that is valid JSON but not a registry is corrupt in the same
    // way: refuse it instead of starting over and handing out numbers twice.
    if (!Array.isArray(doc.records) || !doc.observedAt || typeof doc.observedAt !== 'object') {
      throw new StateFileError('state_corrupt', 'refs registry has an unexpected shape');
    }
    return doc;
  }

  // Every write goes through the same shape check as a read: a document that
  // is not a registry must be surfaced, never repaired in place.
  function mutate(fn) {
    return state.mutate((doc) => {
      if (!Array.isArray(doc.records) || !doc.observedAt || typeof doc.observedAt !== 'object') {
        throw new StateFileError('state_corrupt', 'refs registry has an unexpected shape');
      }
      return fn(doc);
    });
  }

  function prune(doc, at) {
    const cutoff = at - HISTORY_MS;
    doc.records = doc.records.filter((record) => record.releasedAt === null || Date.parse(record.releasedAt) >= cutoff);
  }

  function heldNumber(record) {
    return record.releasedAt === null;
  }

  function chooseNumber(doc, kind, key, at) {
    const held = new Set(doc.records.filter((r) => r.kind === kind && heldNumber(r)).map((r) => r.n));
    const cooling = new Set(doc.records
      .filter((r) => r.kind === kind && r.key !== key && r.releasedAt !== null
        && Date.parse(r.releasedAt) >= at - COOLDOWN_MS)
      .map((r) => r.n));
    for (let n = 1; n <= MAX_N; n += 1) {
      if (!held.has(n) && !cooling.has(n)) return n;
    }
    throw new StateFileError('refs_full', `no free ${PREFIX[kind]} number below ${MAX_N}`);
  }

  function assignIn(doc, { kind, key, title, external }, at) {
    const held = doc.records.find((r) => r.kind === kind && r.key === key && heldNumber(r));
    if (held) {
      const nextTitle = cleanTitle(title);
      if (held.title !== nextTitle) held.title = nextTitle;
      if (external !== undefined) held.external = external;
      return held;
    }

    const heldNums = new Set(doc.records.filter((r) => r.kind === kind && heldNumber(r)).map((r) => r.n));
    const prior = doc.records
      .filter((r) => r.kind === kind && r.key === key && r.releasedAt !== null)
      .sort((a, b) => String(b.releasedAt).localeCompare(String(a.releasedAt)));
    const restorable = prior.find((r) => !heldNums.has(r.n));
    const n = restorable ? restorable.n : chooseNumber(doc, kind, key, at);
    const record = {
      ref: `${PREFIX[kind]}${n}`,
      kind,
      n,
      key,
      title: cleanTitle(title),
      external: external ?? {},
      assignedAt: new Date(at).toISOString(),
      releasedAt: null,
    };
    doc.records.push(record);
    return record;
  }

  function activeRecord(doc, kind, key) {
    return doc.records.find((r) => r.kind === kind && r.key === key && heldNumber(r)) ?? null;
  }

  return {
    file,
    read: readDoc,

    assign({ kind, key, title = '', external = {} } = {}) {
      if (!KINDS.includes(kind)) throw new TypeError(`unknown ref kind: ${kind}`);
      if (typeof key !== 'string' || key === '') throw new TypeError('ref key must be a non-empty string');
      const at = now();
      const record = mutate((doc) => {
        prune(doc, at);
        return copy(assignIn(doc, { kind, key, title, external }, at));
      });
      return record;
    },

    // The only release path for a read: `items` is the complete live set.
    observeComplete(kind, items) {
      if (!KINDS.includes(kind)) throw new TypeError(`unknown ref kind: ${kind}`);
      if (!Array.isArray(items)) throw new TypeError('ref items must be an array');
      const at = now();
      const iso = new Date(at).toISOString();
      const ordered = orderRefItems(kind, items.filter((item) => typeof item?.key === 'string' && item.key !== ''));
      return mutate((doc) => {
        prune(doc, at);
        const keys = new Set(ordered.map((item) => item.key));
        let released = 0;
        let assigned = 0;
        for (const record of doc.records) {
          if (record.kind !== kind || !heldNumber(record)) continue;
          if (!keys.has(record.key)) {
            record.releasedAt = iso;
            released += 1;
          }
        }
        const seen = new Set();
        for (const item of ordered) {
          if (seen.has(item.key)) continue;
          seen.add(item.key);
          const before = activeRecord(doc, kind, item.key);
          const record = assignIn(doc, { kind, key: item.key, title: item.title, external: item.external ?? {} }, at);
          if (!before) assigned += 1;
          else if (item.title !== undefined) record.title = cleanTitle(item.title);
        }
        doc.observedAt[kind] = iso;
        return { assigned, released, held: ordered.length };
      });
    },

    release(kind, key) {
      if (!KINDS.includes(kind)) throw new TypeError(`unknown ref kind: ${kind}`);
      const at = now();
      return mutate((doc) => {
        const record = activeRecord(doc, kind, key);
        if (!record) return null;
        record.releasedAt = new Date(at).toISOString();
        return copy(record);
      });
    },

    refFor(kind, key) {
      const record = activeRecord(readDoc(), kind, key);
      return record ? record.ref : null;
    },

    held(kinds = KINDS) {
      const doc = readDoc();
      const wanted = new Set(typeof kinds === 'string' ? [kinds] : kinds);
      return doc.records
        .filter((record) => heldNumber(record) && wanted.has(record.kind))
        .sort((a, b) => KINDS.indexOf(a.kind) - KINDS.indexOf(b.kind) || a.n - b.n)
        .map((record) => copy(record));
    },

    observedAt(kinds = KINDS) {
      const doc = readDoc();
      const list = typeof kinds === 'string' ? [kinds] : kinds;
      const out = {};
      for (const kind of list) out[kind] = doc.observedAt[kind] ?? null;
      return out;
    },

    resolve(input) {
      const normalized = requireRefInput(input);
      const doc = readDoc();
      const holder = doc.records.find((r) => r.ref === normalized.ref && heldNumber(r)) ?? null;
      const previous = doc.records
        .filter((r) => r.ref === normalized.ref && r.releasedAt !== null
          && Date.parse(r.releasedAt) >= now() - HISTORY_MS)
        .sort((a, b) => String(b.releasedAt).localeCompare(String(a.releasedAt)))
        .map((record) => copy(record));
      return {
        ref: normalized.ref,
        kind: normalized.kind,
        status: holder ? 'active' : previous.length > 0 ? 'released' : 'unknown',
        holder: holder ? copy(holder) : null,
        previous,
      };
    },
  };
}
