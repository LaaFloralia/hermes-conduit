#!/usr/bin/env node
// Acceptance check for the Drive endpoints against a running Bridge.
//
//   bridge/scripts/verify-drive.mjs [--base http://127.0.0.1:9137] [--query "PR動画"]
//
// Pairs a throwaway device through the `laa-bridge` CLI, measures the first
// byte, a middle seek and an abort on a real file, then revokes the device.
// The pairing code and the token never leave this process; only ids and
// measurements are printed. Read-only: nothing in Drive is modified.
//
// Requires the Bridge to hold a Drive authorization (see README). Without one
// every call answers 503 drive_not_configured and this script says so.

import { execFileSync } from 'node:child_process';

const args = process.argv.slice(2);
function option(name, fallback) {
  const index = args.indexOf(`--${name}`);
  return index === -1 ? fallback : args[index + 1];
}

const BASE = option('base', 'http://127.0.0.1:9137');
const QUERY = option('query', 'mp4');
const CLI = option('cli', '/Users/laa/.local/bin/laa-bridge');

function cli(...cliArgs) {
  return execFileSync(CLI, cliArgs, { encoding: 'utf8' });
}

const pair = JSON.parse(cli('pair', '--name', 'verify-drive', '--json'));
const enroll = await fetch(`${BASE}/v1/devices/enroll`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ code: pair.code, name: 'verify-drive' }),
});
if (enroll.status !== 201) {
  console.error(`enroll failed: ${enroll.status} ${(await enroll.text()).slice(0, 200)}`);
  process.exit(1);
}
const { token, deviceId } = (await enroll.json()).data;
const auth = { authorization: `Bearer ${token}` };
const out = { base: BASE, deviceId, checks: {} };

async function json(path) {
  const response = await fetch(`${BASE}${path}`, { headers: auth });
  return { status: response.status, body: await response.json().catch(() => null) };
}

try {
  const search = await json(`/v1/drive/files?query=${encodeURIComponent(QUERY)}&pageSize=25`);
  out.checks.list = { status: search.status, code: search.body?.error?.code ?? null };
  if (search.status !== 200) {
    out.result = 'not_configured_or_failed';
  } else {
    const video = search.body.data.items.find((item) => item.mimeType.startsWith('video/')) ?? search.body.data.items[0];
    if (!video) throw new Error(`no file matched "${QUERY}"`);
    out.checks.file = { name: video.name, size: video.size, mimeType: video.mimeType };

    const meta = await json(`/v1/drive/files/${video.id}`);
    out.checks.metadata = { status: meta.status, kind: meta.body?.data?.kind };

    for (const [label, range] of [
      ['firstByte', 'bytes=0-65535'],
      ['seekMiddle', `bytes=${Math.floor((video.size ?? 0) / 2)}-${Math.floor((video.size ?? 0) / 2) + 262143}`],
    ]) {
      const started = performance.now();
      const response = await fetch(`${BASE}/v1/drive/files/${video.id}/content`, { headers: { ...auth, range } });
      if (!response.body) {
        out.checks[label] = { status: response.status };
        continue;
      }
      const reader = response.body.getReader();
      const first = await reader.read();
      const ttfb = performance.now() - started;
      let bytes = first.value?.length ?? 0;
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.length;
      }
      out.checks[label] = {
        status: response.status,
        contentRange: response.headers.get('content-range'),
        ttfbMs: Math.round(ttfb),
        bytes,
      };
    }

    const controller = new AbortController();
    const aborted = await fetch(`${BASE}/v1/drive/files/${video.id}/content`, {
      headers: { ...auth, range: 'bytes=0-' },
      signal: controller.signal,
    });
    const reader = aborted.body.getReader();
    await reader.read();
    controller.abort();
    await new Promise((resolve) => setTimeout(resolve, 300));
    out.checks.abort = { healthAfterAbort: (await json('/v1/health')).status };

    const beyond = await fetch(`${BASE}/v1/drive/files/${video.id}/content`, {
      headers: { ...auth, range: `bytes=${(video.size ?? 0) + 10}-` },
    });
    out.checks.unsatisfiable = { status: beyond.status, contentRange: beyond.headers.get('content-range') };
    out.result = 'ok';
  }
} finally {
  cli('revoke', deviceId, '--reason', 'verify-drive');
  out.checks.revoked = (await fetch(`${BASE}/v1/drive/files`, { headers: auth })).status;
}

console.log(JSON.stringify(out, null, 2));
