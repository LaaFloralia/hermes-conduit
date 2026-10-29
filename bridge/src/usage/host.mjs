// Host readings for /v1/mac/status (docs/laa/USAGE.md §4).
//
// CPU and memory are sampled inside the Bridge process and cached for 10 s
// (parent decision 2: no new daemon, no collector). Both come from the kernel
// counters Activity Monitor reads, via the system's own readers:
//
//   * CPU: `iostat -c 2 -w 1` reports user/sys/idle for the last second. Node's
//     `os.cpus()` cannot be used on macOS: libuv leaves `times.idle` frozen
//     there, so a tick delta reports a machine as permanently 100% busy.
//   * memory: `vm_stat` page counts plus `sysctl vm.swapusage`. Node's
//     `os.freemem()` reports free pages only, which would show a machine with
//     reclaimable cache as nearly full.
//
// Both readers are short-lived subprocesses of this process (no daemon), and a
// 10 s cache keeps the cost to at most one pair per 10 s.
//
// Free disk is *not* sampled: `laa-storage-guard status` takes ~50 s, so the
// Bridge only reads the status file the daily launchd job already writes
// (USAGE.md §4). The file missing or unparsable is `unavailable`, never 0.

import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { cpus as osCpus, totalmem as osTotalmem } from 'node:os';
import { promisify } from 'node:util';
import { resolveStorageStatusFile } from '../config.mjs';
import {
  DISK_SOURCE,
  HOST_SAMPLER_SOURCE,
  availableItem,
  finiteNumber,
  isoFromMs,
  isoTime,
  round,
  safeText,
  unavailableItem,
} from './items.mjs';

const execFileAsync = promisify(execFile);

export const HOST_SAMPLE_CACHE_MS = 10 * 1000;
export const DISK_STALE_MS = 26 * 60 * 60 * 1000;
const MAX_FINDINGS = 20;

export const CPU_ITEM = Object.freeze({ id: 'host.cpu', kind: 'host.cpu', label: 'CPU', unit: 'percent', source: HOST_SAMPLER_SOURCE });
export const MEMORY_ITEM = Object.freeze({ id: 'host.memory', kind: 'host.memory', label: 'メモリ', unit: 'bytes', source: HOST_SAMPLER_SOURCE });
export const DISK_ITEM = Object.freeze({ id: 'host.disk.free', kind: 'host.disk', label: '空き容量', unit: 'gb', source: DISK_SOURCE });

export function unavailableCpu(reason = 'fetch_failed') {
  return unavailableItem({ ...CPU_ITEM, reason });
}

export function unavailableMemory(reason = 'fetch_failed') {
  return unavailableItem({ ...MEMORY_ITEM, reason });
}

export function unavailableDisk(reason = 'fetch_failed') {
  return unavailableItem({ ...DISK_ITEM, reason });
}

function cpuSnapshot(cpus) {
  let idle = 0;
  let user = 0;
  let sys = 0;
  let total = 0;
  for (const cpu of cpus()) {
    const times = cpu?.times ?? {};
    const fields = ['user', 'nice', 'sys', 'idle', 'irq'].map((key) => finiteNumber(times[key], { max: Number.MAX_SAFE_INTEGER }) ?? 0);
    user += fields[0] + fields[1];
    sys += fields[2] + fields[4];
    idle += fields[3];
    total += fields[0] + fields[1] + fields[2] + fields[3] + fields[4];
  }
  return { idle, user, sys, total };
}

// Darwin: the last line of `iostat -c 2 -w 1` is the previous one-second
// interval; the first line is the average since boot and is not used.
function parseIostat(stdout) {
  const lines = String(stdout ?? '').split('\n').map((line) => line.trim()).filter((line) => line !== '');
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const tokens = lines[index].split(/\s+/);
    if (tokens.length < 6) continue;
    const tail = tokens.slice(-6).map(Number);
    if (tail.some((value) => !Number.isFinite(value))) continue;
    const [user, system, idle] = tail;
    const sum = user + system + idle;
    if (user < 0 || system < 0 || idle < 0 || sum < 99 || sum > 101) continue;
    return { userPercent: user, systemPercent: system, idlePercent: idle };
  }
  return null;
}

async function darwinCpuItem({ exec, observedAt }) {
  let stdout;
  try {
    ({ stdout } = await exec('/usr/sbin/iostat', ['-c', '2', '-w', '1']));
  } catch {
    return unavailableCpu();
  }
  const sample = parseIostat(stdout);
  if (sample === null) return unavailableCpu();
  return availableItem({
    ...CPU_ITEM,
    value: round(sample.userPercent + sample.systemPercent, 1),
    observedAt,
    detail: {
      windowSeconds: 1,
      userPercent: round(sample.userPercent, 1),
      systemPercent: round(sample.systemPercent, 1),
    },
  });
}

function cpuItem(baseline, current, elapsedMs, observedAt) {
  const total = current.total - baseline.total;
  const idle = current.idle - baseline.idle;
  if (!(total > 0)) return unavailableCpu();
  const busy = Math.min(total, Math.max(0, total - idle));
  const windowSeconds = round(Math.max(elapsedMs, 0) / 1000, 1);
  return availableItem({
    ...CPU_ITEM,
    value: round((busy / total) * 100, 1),
    observedAt,
    detail: {
      windowSeconds,
      userPercent: round((Math.max(0, current.user - baseline.user) / total) * 100, 1),
      systemPercent: round((Math.max(0, current.sys - baseline.sys) / total) * 100, 1),
    },
  });
}

function pagesOf(vmStat, name) {
  const match = new RegExp(`^Pages ${name}:\\s+(\\d+)\\.`, 'm').exec(vmStat);
  return match ? Number(match[1]) : null;
}

function swapBytes(swapUsage) {
  const match = /used\s*=\s*([\d.]+)([KMG])/i.exec(swapUsage ?? '');
  if (!match) return null;
  const factor = { K: 1024, M: 1024 ** 2, G: 1024 ** 3 }[match[2].toUpperCase()];
  const value = Number(match[1]);
  return Number.isFinite(value) ? Math.round(value * factor) : null;
}

async function memoryItem({ exec, platform, observedAt }) {
  if (platform !== 'darwin') {
    // No host_statistics64 equivalent is wired on other platforms, and the
    // Bridge only ever runs on the Mac mini; CI must still see the item.
    return unavailableMemory('unsupported');
  }
  let vmStat;
  try {
    ({ stdout: vmStat } = await exec('/usr/bin/vm_stat', []));
  } catch {
    return unavailableMemory('fetch_failed');
  }
  const pageSize = finiteNumber(Number(/page size of (\d+) bytes/.exec(vmStat ?? '')?.[1]), { min: 1 });
  const free = pagesOf(vmStat ?? '', 'free');
  const inactive = pagesOf(vmStat ?? '', 'inactive');
  const speculative = pagesOf(vmStat ?? '', 'speculative') ?? 0;
  const total = osTotalmem();
  if (pageSize === null || free === null || inactive === null || !Number.isFinite(total)) {
    return unavailableMemory('fetch_failed');
  }
  const availableBytes = Math.min(total, (free + inactive + speculative) * pageSize);
  const detail = {
    totalBytes: total,
    availableBytes,
  };
  let swapUsed = null;
  try {
    const { stdout } = await exec('/usr/sbin/sysctl', ['-n', 'vm.swapusage']);
    swapUsed = swapBytes(stdout);
  } catch {
    // Swap is a detail, not the reading: leave it out rather than report 0.
  }
  if (swapUsed !== null) detail.swapUsedBytes = swapUsed;
  return availableItem({
    ...MEMORY_ITEM,
    value: total - availableBytes,
    observedAt,
    detail,
  });
}

export function createHostSampler({
  now = () => Date.now(),
  cpus = osCpus,
  exec = execFileAsync,
  platform = process.platform,
  cacheMs = HOST_SAMPLE_CACHE_MS,
} = {}) {
  // The tick baseline is only used off Darwin (Linux CI, where idle advances).
  let baseline = platform === 'darwin' ? null : cpuSnapshot(cpus);
  let baselineAt = now();
  let cached = null;
  let inflight = null;

  async function tickCpu(observedAt) {
    let current;
    try {
      current = cpuSnapshot(cpus);
    } catch {
      return unavailableCpu();
    }
    const startedAt = now();
    const item = cpuItem(baseline, current, startedAt - baselineAt, observedAt);
    baseline = current;
    baselineAt = startedAt;
    return item;
  }

  async function sample() {
    const observedAt = isoFromMs(now());
    const cpu = platform === 'darwin'
      ? await darwinCpuItem({ exec, observedAt })
      : await tickCpu(observedAt);
    const memory = await memoryItem({ exec, platform, observedAt });
    return { cpu, memory };
  }

  return {
    async read() {
      const at = now();
      if (cached !== null && at - cached.at < cacheMs) return cached.value;
      if (inflight !== null) return inflight;
      inflight = sample()
        .then((value) => {
          cached = { at: now(), value };
          return value;
        })
        .finally(() => {
          inflight = null;
        });
      return inflight;
    },
  };
}

function findingsOf(value) {
  if (!Array.isArray(value)) return [];
  const findings = [];
  for (const entry of value.slice(0, MAX_FINDINGS)) {
    const text = safeText(entry, 200);
    if (text !== null) findings.push(text);
  }
  return findings;
}

export async function readDiskStatus({ file = resolveStorageStatusFile(), now = () => Date.now(), staleMs = DISK_STALE_MS } = {}) {
  let raw;
  try {
    raw = await readFile(file, 'utf8');
  } catch (error) {
    // ENOENT means the daily guard never wrote a status here; anything else is
    // a read failure. Both are reported, neither becomes 0 GB.
    return unavailableDisk(error?.code === 'ENOENT' ? 'not_configured' : 'fetch_failed');
  }
  let document;
  try {
    document = JSON.parse(raw);
  } catch {
    return unavailableDisk('fetch_failed');
  }
  if (!document || typeof document !== 'object' || Array.isArray(document)) return unavailableDisk('fetch_failed');
  const checkedAt = isoTime(document.checked_at);
  const freeGb = finiteNumber(document.free_gb);
  const totalGb = finiteNumber(document.total_gb);
  if (checkedAt === null || freeGb === null || totalGb === null) return unavailableDisk('fetch_failed');
  const detail = {
    // The guard watches the boot volume; the status file does not name it.
    volume: '/',
    totalGb,
    findings: findingsOf(document.findings),
  };
  const level = safeText(document.level, 16);
  if (level !== null) detail.level = level;
  return availableItem({
    ...DISK_ITEM,
    value: freeGb,
    observedAt: checkedAt,
    stale: now() - Date.parse(checkedAt) > staleMs,
    detail,
  });
}
