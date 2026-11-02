// Adapter for the existing Brain search path: the `laa-brain` CLI
// (hq/tools/BRAIN-SEARCH.md). The Bridge does not reimplement ranking, the area
// policy or the re-ranker — it runs the same command a person would run and
// maps its JSON to the Bridge envelope.
//
// Bridge searches always use --no-jev. Note bodies never go to a model,
// including when an older client sends rerank=1.

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
    args.push('--no-jev'); // Bridge must never transmit note bodies to models.
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
      let outBytes = 0;
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
      child.stderr?.on('data', () => {
        // Discard stderr: it may include note content and must not reach logs.
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
          reject(new BridgeError(503, 'brain_search_failed',
            'the Brain search failed', { retryable: true }));
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
