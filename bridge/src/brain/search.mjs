// Adapter for the existing Brain search path: the `laa-brain` CLI
// (hq/tools/BRAIN-SEARCH.md). The Bridge does not reimplement ranking, the area
// policy or the re-ranker — it runs the same command a person would run and
// maps its JSON to the Bridge envelope.
//
// The CLI sends scrubbed passages to the local judgement gateway only when the
// re-ranker is enabled. The Bridge passes `--no-jev` unless the request asks for
// `rerank=1`: a phone search must not create a new path that ships Brain excerpts
// to another model without the owner asking for it.

import { spawn } from 'node:child_process';
import { BridgeError } from '../errors.mjs';

const MAX_OUTPUT_BYTES = 2 * 1024 * 1024;

export function brainSearchAdapter({
  bin,
  timeoutMs = 25_000,
  spawnImpl = spawn,
  maxOutput = MAX_OUTPUT_BYTES,
} = {}) {
  return async function search({ query, k = 5, areas = [], adopted = false, rerank = false }) {
    const args = ['search', query, '-k', String(k), '--json'];
    if (adopted) args.push('--adopted');
    if (!rerank) args.push('--no-jev');
    for (const area of areas) args.push('--area', area);

    return new Promise((resolvePromise, reject) => {
      let child;
      try {
        child = spawnImpl(bin, args, { stdio: ['ignore', 'pipe', 'pipe'], env: process.env });
      } catch {
        reject(new BridgeError(503, 'brain_search_unavailable', 'the Brain search CLI could not be started', { retryable: true }));
        return;
      }
      const out = [];
      const err = [];
      let outBytes = 0;
      let errBytes = 0;
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        child.kill('SIGKILL');
        reject(new BridgeError(503, 'brain_search_timeout', 'the Brain search did not finish in time', { retryable: true }));
      }, timeoutMs);

      child.stdout?.on('data', (chunk) => {
        outBytes += chunk.length;
        if (outBytes > maxOutput) child.kill('SIGKILL');
        else out.push(chunk);
      });
      child.stderr?.on('data', (chunk) => {
        errBytes += chunk.length;
        if (errBytes <= 4096) err.push(chunk); // enough for a message, never a dump
      });
      child.on('error', () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        reject(new BridgeError(503, 'brain_search_unavailable', 'the Brain search CLI could not be started', { retryable: true }));
      });
      child.on('close', (code) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (code !== 0) {
          const detail = Buffer.concat(err).toString('utf8').trim().split('\n').pop() ?? '';
          reject(new BridgeError(503, 'brain_search_failed',
            `the Brain search failed${detail ? `: ${detail.slice(0, 200)}` : ''}`, { retryable: true }));
          return;
        }
        let parsed;
        try {
          parsed = JSON.parse(Buffer.concat(out).toString('utf8'));
        } catch {
          reject(new BridgeError(503, 'brain_search_failed', 'the Brain search returned unreadable output', { retryable: true }));
          return;
        }
        if (!parsed || !Array.isArray(parsed.results)) {
          reject(new BridgeError(503, 'brain_search_failed', 'the Brain search returned an unexpected shape', { retryable: true }));
          return;
        }
        resolvePromise(parsed);
      });
    });
  };
}

// Test double: the same contract, no process.
export function fakeBrainSearch(handler) {
  return async function search(request) {
    const result = await handler(request);
    if (result instanceof Error) throw result;
    return result;
  };
}
