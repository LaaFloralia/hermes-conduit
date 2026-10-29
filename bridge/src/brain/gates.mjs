// Preconditions the Bridge checks before it creates a note in the Brain vault
// (docs/laa/BRAIN-WRITE.md §4-2 and §5).
//
// The checks are read-only and side-effect free. They are adapters so tests can
// drive every refusal without a real Syncthing or git; in production they look
// at material that already exists on the Mac:
//
//   git         the vault's own .git (branch master, no operation in progress)
//   Syncthing   /rest/db/status using the API key from Syncthing's config.xml
//               (existing credential; never logged, never returned)
//   disk        statfs on the vault
//   journal     the out-of-vault journal file (§4-5)

import { existsSync, readFileSync, statfsSync } from 'node:fs';
import { join } from 'node:path';
import { BridgeError } from '../errors.mjs';

const MIN_FREE_BYTES = 64 * 1024 * 1024;

export function createGitGate({ vaultRoot }) {
  const gitDir = join(vaultRoot, '.git');
  const markers = ['index.lock', 'rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD'];

  return function checkGit() {
    if (!existsSync(gitDir)) {
      throw new BridgeError(503, 'brain_git_unavailable',
        'the vault is not a git checkout; the sync state cannot be verified', { retryable: true });
    }
    for (const marker of markers) {
      if (existsSync(join(gitDir, marker))) {
        throw new BridgeError(423, 'brain_git_busy',
          `the vault git checkout has ${marker}; retry after the sync finishes`, { retryable: true });
      }
    }
    let head;
    try {
      head = readFileSync(join(gitDir, 'HEAD'), 'utf8').trim();
    } catch {
      throw new BridgeError(503, 'brain_git_unavailable', 'the vault git HEAD is unreadable', { retryable: true });
    }
    const branch = head.startsWith('ref: refs/heads/') ? head.slice('ref: refs/heads/'.length) : null;
    if (branch !== 'master') {
      // vault-git-sync only operates on master; a create on another branch
      // would be neither committed nor pushed by the existing job.
      throw new BridgeError(423, 'brain_git_branch',
        `the vault git checkout is on ${branch ?? 'a detached HEAD'}, not master`, { retryable: true });
    }
    return { branch, head };
  };
}

export function createDiskGate({ vaultRoot, minFreeBytes = MIN_FREE_BYTES }) {
  return function checkDisk() {
    let stats;
    try {
      stats = statfsSync(vaultRoot);
    } catch {
      throw new BridgeError(503, 'brain_vault_unavailable', 'the Brain vault is not available', { retryable: true });
    }
    const freeBytes = Number(stats.bavail) * Number(stats.bsize);
    if (freeBytes < minFreeBytes) {
      throw new BridgeError(503, 'brain_vault_no_space',
        `the Brain vault has less than ${Math.round(minFreeBytes / 1048576)} MB free`, { retryable: true });
    }
    return { freeBytes };
  };
}

export function createSyncthingGate({
  configPath,
  baseUrl,
  folder,
  timeoutMs = 3000,
  fetchImpl = (...args) => globalThis.fetch(...args),
  readFile = readFileSync,
}) {
  function apiKey() {
    let xml;
    try {
      xml = readFile(configPath, 'utf8');
    } catch {
      throw new BridgeError(503, 'brain_sync_unavailable',
        'the Syncthing API key is not readable; the sync state cannot be verified', { retryable: true });
    }
    const match = /<apikey>([^<]+)<\/apikey>/.exec(xml);
    if (!match) {
      throw new BridgeError(503, 'brain_sync_unavailable',
        'the Syncthing API key is not configured; the sync state cannot be verified', { retryable: true });
    }
    return match[1].trim();
  }

  return async function checkSyncthing() {
    const url = `${baseUrl}/rest/db/status?folder=${encodeURIComponent(folder)}`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let response;
    try {
      response = await fetchImpl(url, { headers: { 'x-api-key': apiKey() }, signal: controller.signal });
    } catch {
      throw new BridgeError(503, 'brain_sync_unavailable',
        'the Syncthing control API is unreachable; the sync state cannot be verified', { retryable: true });
    } finally {
      clearTimeout(timer);
    }
    if (!response.ok) {
      throw new BridgeError(503, 'brain_sync_unavailable',
        `Syncthing returned ${response.status} for the ${folder} folder`, { retryable: true });
    }
    let status;
    try {
      status = await response.json();
    } catch {
      throw new BridgeError(503, 'brain_sync_unavailable', 'Syncthing returned an unreadable status', { retryable: true });
    }
    // The full `state` vocabulary is still unresolved (BRAIN-WRITE §8), so a
    // new path is refused on the conditions that are unambiguous: a stopped or
    // paused folder, and recorded errors. Unlike a replacement, a create has no
    // check→rename window, so a scan in progress is not a reason to refuse.
    if (status.paused === true) {
      throw new BridgeError(503, 'brain_sync_paused',
        `the Syncthing folder ${folder} is paused`, { retryable: true });
    }
    if (Number(status.errors ?? 0) > 0 || Number(status.pullErrors ?? 0) > 0) {
      throw new BridgeError(503, 'brain_sync_error',
        `the Syncthing folder ${folder} reports errors`, { retryable: true });
    }
    return {
      state: status.state ?? null,
      errors: Number(status.errors ?? 0),
      pullErrors: Number(status.pullErrors ?? 0),
      needFiles: status.needFiles ?? null,
    };
  };
}
