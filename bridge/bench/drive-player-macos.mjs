// Reproducible, synthetic-only measurement of the current iOS player class
// compiled against macOS AVFoundation. No Google account or simulator is used.
// Run: node bridge/bench/drive-player-macos.mjs [repetitions] [chunkKiB] [idealCacheMs] [bytes] [rttMs] [megabitsPerSecond]
// Requires ffmpeg/libx264 and swiftc. Temporary fixture and binary are removed.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { Readable } from 'node:stream';
import { startBridge } from '../test/helpers.mjs';
import { parseRange } from '../src/routes/drive.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const repetitions = Number(process.argv[2] ?? '10');
const chunkKiB = Number(process.argv[3] ?? '256');
const idealCacheMs = Number(process.argv[4] ?? '0');
const transport = process.argv[5] ?? 'bytes';
const rttMs = Number(process.argv[6] ?? '50');
const megabitsPerSecond = Number(process.argv[7] ?? '20');
assert.ok(Number.isInteger(repetitions) && repetitions >= 1 && repetitions <= 100);
assert.ok(Number.isInteger(chunkKiB) && chunkKiB >= 1 && chunkKiB <= 2048);
assert.ok(Number.isInteger(idealCacheMs) && idealCacheMs >= 0 && idealCacheMs <= 5000);
assert.equal(transport, 'bytes', 'only the existing transport is retained');
assert.ok(Number.isInteger(rttMs) && rttMs >= 0 && rttMs <= 2000);
assert.ok(Number.isFinite(megabitsPerSecond) && megabitsPerSecond > 0 && megabitsPerSecond <= 1000);
const tmp = mkdtempSync(join(tmpdir(), 'laa-drive-bench-'));
let bridge;
try {
  const fixture = join(tmp, 'synthetic.mp4');
  execFileSync('ffmpeg', [
    '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=15:duration=6',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100:duration=6',
    '-c:v', 'libx264', '-profile:v', 'main', '-preset', 'ultrafast', '-g', '15',
    '-b:v', '4M', '-minrate', '4M', '-maxrate', '4M', '-bufsize', '8M',
    '-x264-params', 'nal-hrd=cbr:force-cfr=1', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-b:a', '64k', '-movflags', '+faststart', '-t', '6', '-y', fixture,
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  const size = statSync(fixture).size;
  assert.ok(size > 0 && size <= 4 * 1024 * 1024, `fixture exceeds 4 MiB (${size})`);
  const video = readFileSync(fixture);
  const state = { metadataLookups: 0, metadata: 0, media: 0, bytes: 0, ranges: [] };
  const item = { name: 'synthetic.mp4', mimeType: 'video/mp4', kind: 'file',
    size, downloadable: true, modifiedAt: null, parents: [], webViewLink: null };
  const idealCache = new Map();
  const drive = {
    async get(id) {
      state.metadataLookups += 1;
      const cached = idealCache.get(id);
      if (cached && cached.expires > Date.now()) return cached.found;
      state.metadata += 1;
      await sleep(rttMs); // Bridge-to-Google RTT, metadata request.
      const found = /^fixture_video_\d+$/.test(id) ? { item: { ...item, id } } : null;
      // Idealized cache assumes a constant version/permission; this is only a
      // performance bound, not a safe implementation of a Drive cache.
      if (idealCacheMs && found) idealCache.set(id, { found, expires: Date.now() + idealCacheMs });
      return found;
    },
    async open(id, { range, signal }) {
      state.media += 1;
      state.ranges.push(range);
      await sleep(rttMs, undefined, { signal }); // Bridge-to-Google RTT, media request.
      if (!/^fixture_video_\d+$/.test(id)) return null;
      const parsed = parseRange(range, size);
      assert.equal(parsed.kind, 'range');
      const start = parsed.start;
      const end = parsed.end;
      const headers = new Headers({
        'content-type': 'video/mp4', 'accept-ranges': 'bytes',
        'content-range': `bytes ${start}-${end}/${size}`, 'content-length': String(end - start + 1),
      });
      const stream = Readable.from((async function* () {
        // Equal-rate hops pipeline, so rate-limit only once.
        for (let offset = start; offset <= end; offset += 32 * 1024) {
          const part = video.subarray(offset, Math.min(end + 1, offset + 32 * 1024));
          await sleep(part.length * 8 / (megabitsPerSecond * 1_000), undefined, { signal });
          state.bytes += part.length;
          yield part;
        }
      })());
      return { status: 206, headers, stream };
    },
  };
  bridge = await startBridge({ drive });
  const token = await bridge.token(); // Throwaway pairing; never printed or written to source.
  const playerSource = readFileSync(join(root, 'Conduit/LAA/Drive/LAADrivePlayer.swift'), 'utf8');
  const transportSource = readFileSync(join(root, 'Conduit/LAA/Drive/LAADriveTransport.swift'), 'utf8');
  assert.match(transportSource, /static let chunkSize = 256 \* 1024/, 'update the harness if the iOS chunk size changes');
  const start = playerSource.indexOf('@MainActor\nfinal class LAADrivePlayer:');
  const end = playerSource.indexOf('\nstruct LAADrivePlayerView:', start);
  assert.ok(start >= 0 && end > start, 'could not locate the current player class');
  const harness = readFileSync(join(here, 'drive-player-macos.swift'), 'utf8');
  const swiftSource = join(tmp, 'bench.swift');
  writeFileSync(swiftSource, `${harness}\n${playerSource.slice(start, end)}\n`);
  const binary = join(tmp, 'drive-player-bench');
  execFileSync('swiftc', ['-swift-version', '5', '-D', 'LAA_BUILD', '-O', '-parse-as-library', swiftSource,
    '-o', binary], { stdio: ['ignore', 'pipe', 'pipe'] });
  const result = await new Promise((resolveProcess, reject) => {
    const child = spawn(binary, [], {
      env: { ...process.env, LAA_BENCH_BASE: bridge.base, LAA_BENCH_FAKE_TOKEN: token,
        LAA_BENCH_REPETITIONS: String(repetitions), LAA_BENCH_CHUNK_BYTES: String(chunkKiB * 1024),
        LAA_BENCH_RTT_MS: String(rttMs) },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (data) => { stdout += data; });
    child.stderr.on('data', (data) => { stderr += data; });
    child.on('error', reject);
    child.on('close', (code) => code === 0 ? resolveProcess(stdout)
      : reject(new Error(`benchmark exited ${code}: ${stderr.slice(0, 3000)}`)));
  });
  const trials = result.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  assert.equal(trials.length, repetitions);
  function p90(field) {
    const sorted = trials.map((trial) => trial[field]).sort((a, b) => a - b);
    return Math.round(sorted[Math.ceil(sorted.length * 0.9) - 1]);
  }
  console.log(JSON.stringify({ fixtureBytes: size, fixtureSeconds: 6,
    network: `${rttMs} ms RTT per hop; ${megabitsPerSecond} Mbit/s per hop; no packet loss`,
    platform: 'macOS AVFoundation; current iOS player class; modeled transport; not iPhone',
    repetitions, chunkKiB, transport, idealizedMetadataCacheMs: idealCacheMs,
    startupP90Ms: p90('startupMs'), seekP90Ms: p90('seekMs'),
    startupRequests: trials.map((trial) => trial.startupRequests),
    seekRequests: trials.map((trial) => trial.seekRequests),
    metadataLookups: state.metadataLookups, upstreamMetadataRequests: state.metadata, upstreamMediaRequests: state.media,
    upstreamBytes: state.bytes, ranges: state.ranges, trials }, null, 2));
} finally {
  await bridge?.close();
  rmSync(tmp, { recursive: true, force: true });
}
