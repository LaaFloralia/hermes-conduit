#!/usr/bin/env node
// Operator check of the Brain surface against the real vault (ROADMAP 25).
//
// Runs the documented create-only flow once over loopback, then reads the note
// back and compares its hash. It does NOT delete anything: the caller decides
// what to do with the note (this repo's convention is to move it to the vault's
// trash, never to unlink it). Prints a JSON summary without tokens or note
// bodies.
//
//   LAA_BRIDGE_URL=http://127.0.0.1:9137 LAA_BRIDGE_TOKEN=… \
//     node bridge/scripts/verify-brain.mjs [--path "Inbox/_bridge-create-verify.md"] [--search デザイン]
//
// Not part of `npm test`: CI has no vault, no token and must not write notes.

import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
function flag(name, fallback) {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : fallback;
}

const base = (process.env.LAA_BRIDGE_URL ?? 'http://127.0.0.1:9137').replace(/\/+$/, '');
const token = process.env.LAA_BRIDGE_TOKEN;
if (!token) {
  process.stderr.write('verify-brain: LAA_BRIDGE_TOKEN is required\n');
  process.exit(2);
}

const now = new Date();
const stamp = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, '0')}${String(now.getDate()).padStart(2, '0')}-${String(now.getHours()).padStart(2, '0')}${String(now.getMinutes()).padStart(2, '0')}${String(now.getSeconds()).padStart(2, '0')}`;
const path = flag('path', `Inbox/_bridge-create-verify-${stamp}.md`);
const searchQuery = flag('search', 'デザイン');
const label = `LAA Bridge create-only verification ${stamp}`;
const content = `# ${label}\n\nCreated by bridge/scripts/verify-brain.mjs. Safe to move to trash.\n`;

async function call(route, { method = 'GET', body, key } = {}) {
  const headers = { authorization: `Bearer ${token}` };
  if (body !== undefined) headers['content-type'] = 'application/json';
  if (key) headers['idempotency-key'] = key;
  const response = await fetch(`${base}${route}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  return { status: response.status, body: text === '' ? null : JSON.parse(text) };
}

const summary = { base, path, steps: {} };

const gates = await call('/v1/brain/gates');
summary.steps.gates = { status: gates.status, data: gates.body?.data };

const list = await call('/v1/brain/files?limit=5');
summary.steps.list = {
  status: list.status,
  total: list.body?.data?.total,
  first: list.body?.data?.items?.[0]?.path ?? null,
  areas: list.body?.data?.areas,
};

const search = await call(`/v1/brain/search?q=${encodeURIComponent(searchQuery)}&k=3`);
summary.steps.search = {
  status: search.status,
  found: search.body?.data?.found,
  matchBasis: search.body?.data?.matchBasis,
  top: search.body?.data?.results?.[0]?.path ?? null,
};

const created = await call('/v1/brain/files', {
  method: 'POST',
  key: `verify-brain-${stamp}`,
  body: { path, content, onConflict: 'suffix' },
});
summary.steps.create = {
  status: created.status,
  path: created.body?.data?.path,
  id: created.body?.data?.id,
  contentHash: created.body?.data?.contentHash,
  suffixApplied: created.body?.data?.suffixApplied,
  error: created.body?.error?.code ?? null,
};

if (created.status !== 201) {
  console.log(JSON.stringify(summary, null, 2));
  process.exit(1);
}

const actualPath = created.body.data.path;
const read = await call(`/v1/brain/files/${created.body.data.id}?area=inbox`);
summary.steps.read = {
  status: read.status,
  matchesSentBody: read.body?.data?.text === content,
  contentHash: read.body?.data?.contentHash,
  statusLabel: read.body?.data?.status,
};
summary.steps.read.hashMatchesCreate = read.body?.data?.contentHash === created.body.data.contentHash;

const duplicate = await call('/v1/brain/files', {
  method: 'POST',
  key: `verify-brain-dup-${stamp}`,
  body: { path: actualPath, content, onConflict: 'reject' },
});
summary.steps.duplicateRejected = {
  status: duplicate.status,
  code: duplicate.body?.error?.code ?? null,
};

const ok = summary.steps.read.matchesSentBody
  && summary.steps.read.hashMatchesCreate
  && duplicate.status === 409;

const outDir = process.env.LAA_BRIDGE_VERIFY_OUT;
if (outDir) {
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'verify-brain.json'), `${JSON.stringify(summary, null, 2)}\n`);
}

console.log(JSON.stringify({ ok, ...summary }, null, 2));
if (!ok) process.exit(1);
