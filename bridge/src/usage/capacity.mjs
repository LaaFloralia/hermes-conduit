import { statfs } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { availableMemoryBytes } from './host.mjs';
import { googleConnection } from '../google/connection.mjs';
import { availableItem, unavailableItem, isoFromMs } from './items.mjs';

const CACHE_MS = 10_000;
const FRESH_MS = 10 * 60_000;
const GIB = 1024 ** 3;
const definitions = [
  ['capacity.mac-mini.memory', 'Mac mini · Memory', 'Mac mini', 'memory', 'bridge-host-sampler'],
  ['capacity.mac-mini.ssd', 'Mac mini · SSD', 'Mac mini', 'ssd', 'filesystem'],
  ['capacity.google-drive', 'Google Drive', 'Google Drive', 'google-storage', 'google-drive'],
  ['capacity.macbook.memory', 'MacBook · Memory', 'MacBook', 'memory', 'macbook-ssh'],
  ['capacity.macbook.ssd', 'MacBook · SSD', 'MacBook', 'ssd', 'macbook-ssh'],
  ['capacity.icloud', 'iCloud', 'iCloud', 'cloud', 'unsupported'],
].map(([id, label, deviceLabel, resourceType, source]) => ({ id, label, deviceLabel, resourceType, source, kind: 'capacity', unit: 'bytes' }));

function unavailable(def, reason = 'fetch_failed') {
  return unavailableItem({ ...def, reason });
}
function bytes(value) {
  const n = typeof value === 'string' && /^\d+$/.test(value) ? Number(value) : value;
  return Number.isSafeInteger(n) && n >= 0 ? n : null;
}
function project(def, sample, now) {
  if (!sample) return unavailable(def);
  if (sample.reason) return unavailable(def, sample.reason);
  const observed = Date.parse(sample.observedAt);
  const total = bytes(sample.totalBytes), available = bytes(sample.availableBytes), used = bytes(sample.usedBytes);
  if (!Number.isFinite(observed) || observed > now || total === null || total === 0 || available === null || used === null || available > total || (def.resourceType === 'google-storage' ? available !== Math.max(0, total - used) : used > total || used + available !== total)) return unavailable(def);
  const warning = def.resourceType === 'ssd' ? 80 * GIB : def.resourceType === 'google-storage' ? Math.floor(total * 0.1) : null;
  const critical = def.resourceType === 'ssd' ? 40 * GIB : def.resourceType === 'google-storage' ? Math.floor(total * 0.02) : null;
  const status = def.resourceType === 'google-storage'
    ? used / total >= 0.98 ? 'critical' : used / total >= 0.90 ? 'warning' : 'normal'
    : critical !== null && available < critical ? 'critical' : warning !== null && available < warning ? 'warning' : warning !== null ? 'normal' : 'unknown';
  const driveUsage = bytes(sample.driveUsageBytes);
  const extra = def.resourceType === 'google-storage' ? { driveUsageBytes: driveUsage } : {};
  return availableItem({ ...def, value: used, observedAt: isoFromMs(observed), stale: now >= observed + FRESH_MS,
    detail: { totalBytes: total, availableBytes: available, freshUntil: isoFromMs(observed + FRESH_MS), deviceLabel: def.deviceLabel, resourceType: def.resourceType, status, warningFreeBytes: warning, criticalFreeBytes: critical, ...extra } });
}

export async function readGoogleCapacity({ connection = googleConnection } = {}) {
  const response = await connection.request('https://www.googleapis.com/drive/v3/about?fields=user(emailAddress),storageQuota(limit,usage,usageInDrive)', {}, 'drive');
  const data = await connection.json(response, 'drive');
  if (data?.user?.emailAddress?.toLowerCase() !== 'floralia@laa-inc.com') throw new Error('account mismatch');
  const totalBytes = bytes(data.storageQuota?.limit), usedBytes = bytes(data.storageQuota?.usage);
  if (totalBytes === null || usedBytes === null) throw new Error('invalid quota');
  return { totalBytes, usedBytes, availableBytes: Math.max(0, totalBytes - usedBytes), driveUsageBytes: bytes(data.storageQuota?.usageInDrive) };
}

const execFileAsync = promisify(execFile);
const script = fileURLToPath(new URL('../../scripts/macbook-capacity.sh', import.meta.url));
const template = fileURLToPath(new URL('../../scripts/macbook-capacity.env.tpl', import.meta.url));

export function parseMacBookCapacity(output) {
  if (typeof output !== 'string') throw new Error('invalid sample');
  const match = /^__MEMORY__\n(\d+)\n__VM__\n([\s\S]+?)\n__DISK__\n([\s\S]+?)\s*$/.exec(output.replaceAll('\r\n', '\n'));
  if (!match) throw new Error('invalid sample');
  const totalMemory = bytes(match[1]);
  const availableMemory = availableMemoryBytes(match[2], totalMemory);
  const rows = match[3].split('\n');
  const disk = rows.length === 2 ? rows[1].trim().split(/\s+/) : [];
  const totalDisk = bytes(disk[1]), availableDisk = bytes(disk[3]);
  if (availableMemory === null || disk.length < 6 || totalDisk === null || totalDisk === 0 || availableDisk === null || availableDisk > totalDisk || !Number.isSafeInteger(totalDisk * 1024) || !Number.isSafeInteger(availableDisk * 1024)) throw new Error('invalid sample');
  return {
    memory: { totalBytes: totalMemory, availableBytes: availableMemory, usedBytes: totalMemory - availableMemory },
    ssd: { totalBytes: totalDisk * 1024, availableBytes: availableDisk * 1024, usedBytes: (totalDisk - availableDisk) * 1024 },
  };
}

export async function readMacBookCapacity({ exec = execFileAsync } = {}) {
  try {
    const { stdout } = await exec('/Users/laa/.config/laa/op-run-batch.sh', [template, script], { timeout: 35_000, maxBuffer: 64 * 1024 });
    return parseMacBookCapacity(stdout);
  } catch {
    throw new Error('MacBook capacity unavailable');
  }
}

export function createCapacitySource({ host, now = Date.now, cacheMs = CACHE_MS, diskStat = () => statfs('/'), google = readGoogleCapacity, macbook = readMacBookCapacity } = {}) {
  const cached = [null, null, null, null];
  const inflight = [null, null, null, null];
  const attemptedAt = [null, null, null, null];
  let closed = false;
  const readers = [
    async () => {
      const { memory } = await host.read();
      if (memory.availability !== 'available') return { reason: memory.nullReason ?? 'fetch_failed' };
      return { totalBytes: memory.detail?.totalBytes, availableBytes: memory.detail?.availableBytes, usedBytes: memory.value, observedAt: memory.observedAt };
    },
    async () => {
      const s = await diskStat();
      const totalBytes = s.blocks * s.bsize, availableBytes = s.bavail * s.bsize;
      return { totalBytes, availableBytes, usedBytes: totalBytes - availableBytes };
    },
    google,
    macbook,
  ];
  function refresh(index) {
    if (closed || inflight[index]) return inflight[index];
    const started = now();
    attemptedAt[index] = started;
    inflight[index] = Promise.resolve().then(readers[index]).then(value => {
      const observedAt = value.observedAt ?? isoFromMs(started);
      if (index === 3 && [3, 4].some(i => project(definitions[i], { ...value[i === 3 ? 'memory' : 'ssd'], observedAt }, now()).availability !== 'available')) throw new Error('invalid sample');
      if (!closed) cached[index] = { ...value, observedAt };
    }).catch(error => {
      if (!closed) cached[index] = { reason: /auth_required|access_denied/.test(error?.code ?? '') ? 'auth_required' : 'fetch_failed' };
    }).finally(() => { inflight[index] = null; });
    return inflight[index];
  }
  return {
    read() {
      const at = now();
      for (let i = 0; i < 4; i++) {
        const interval = i >= 2 ? 5 * 60_000 : cacheMs;
        if (attemptedAt[i] === null || at < attemptedAt[i] || at - attemptedAt[i] >= interval) refresh(i);
      }
      return definitions.map((def, i) => {
        if (i < 3) return project(def, cached[i], at);
        if (i === 5) return unavailable(def, 'unsupported');
        const sample = cached[3];
        return project(def, sample?.reason ? sample : sample && { ...sample[i === 3 ? 'memory' : 'ssd'], observedAt: sample.observedAt }, at);
      });
    },
    refresh,
    close() { closed = true; },
  };
}
