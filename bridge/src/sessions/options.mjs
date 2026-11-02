// /v1/session-options — the model/effort choices the app offers for a new
// session, read from the HQ model table (hq/harness/models.json) that
// laa-personal-agent resolves profiles against. Reading the same file keeps the
// app from offering a profile the wrapper would refuse.

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { BridgeError } from '../errors.mjs';

const DEFAULT_PROFILE = 'opus-high';

export function resolveModelsFile(env = process.env) {
  return env.LAA_BRIDGE_MODELS_FILE || join(homedir(), 'hq', 'harness', 'models.json');
}

// Mirrors the wrapper's fast mapping: Claude Opus and Codex have a fast tier.
export function fastSupported(harness, modelId) {
  return (harness === 'claude' && typeof modelId === 'string' && modelId.startsWith('claude-opus')) || harness === 'codex';
}

export function sessionOptionsFrom(table) {
  const aliases = table?.aliases ?? {};
  const profiles = Object.entries(table?.profiles ?? {})
    .filter(([id, profile]) => profile && profile.manual !== true && !Object.hasOwn(aliases, id))
    .filter(([, profile]) => ['claude', 'codex', 'dsh'].includes(profile.harness) && typeof profile.effort === 'string')
    .map(([id, profile]) => {
      const model = table.models?.[profile.model] ?? {};
      return {
        id,
        label: model.label ?? profile.model,
        provider: profile.harness,
        model: model.modelId ?? profile.model,
        effort: profile.effort,
        fast: fastSupported(profile.harness, model.modelId),
      };
    });
  return {
    profiles,
    defaultProfile: profiles.some((item) => item.id === DEFAULT_PROFILE) ? DEFAULT_PROFILE : (profiles[0]?.id ?? null),
    defaultMode: 'bypass',
  };
}

export function sessionOptionsReader({ file = resolveModelsFile() } = {}) {
  return () => {
    let table;
    try {
      table = JSON.parse(readFileSync(file, 'utf8'));
    } catch {
      throw new BridgeError(503, 'options_unavailable', 'the model table cannot be read', { retryable: true });
    }
    const options = sessionOptionsFrom(table);
    if (options.profiles.length === 0) {
      throw new BridgeError(503, 'options_unavailable', 'the model table lists no usable profile', { retryable: true });
    }
    return options;
  };
}
