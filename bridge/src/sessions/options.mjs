// /v1/session-options — the model/effort choices the app offers for a new
// session, read from the HQ model table (hq/harness/models.json) that
// laa-personal-agent resolves profiles against. Reading the same file keeps the
// app from offering a profile the wrapper would refuse.

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { BridgeError } from '../errors.mjs';
import { entranceProfiles } from './entrance-profiles.mjs';

const DEFAULT_PROFILE = 'opus-high';

export function resolveModelsFile(env = process.env) {
  return env.LAA_BRIDGE_MODELS_FILE || join(homedir(), 'hq', 'harness', 'models.json');
}

// Mirrors the wrapper's fast mapping: Claude Opus and Codex have a fast tier.
export function fastSupported(harness, modelId) {
  return (harness === 'claude' && typeof modelId === 'string' && modelId.startsWith('claude-opus')) || harness === 'codex';
}

// HQ writes a wire id as {{id:<model key>}} and expands it on each read
// (hq/harness/models.py). The Bridge reads the raw file, so it expands the same
// way. An unknown key stays as written and matches nothing.
function expandModelId(table, value) {
  if (typeof value !== 'string') return value;
  return value.replace(/\{\{id:([^{}]+)\}\}/g, (written, key) =>
    (typeof table.models?.[key]?.modelId === 'string' ? table.models[key].modelId : written));
}

// Manual paid routes require an exact manual Work entrance. Other manual
// profiles may also be named by HQ dispatch.manual_profiles; neither changes
// the automatic default.
function manualEntranceExists(table, profile) {
  const modelId = table.models?.[profile.model]?.modelId;
  const wireModel = profile.harness === 'hermes-claude-api' ? `anthropic:${modelId}`
    : profile.harness === 'dsh-venice' ? JSON.stringify(['venice', modelId]) : modelId;
  return typeof modelId === 'string' && (table.entrances ?? []).some((entry) =>
    entry.kind === 'paseo' && entry.status === 'manual' &&
    entry.paseo?.provider === profile.harness && expandModelId(table, entry.paseo?.model) === wireModel &&
    (entry.paseo?.thinking === profile.effort || (profile.harness === 'dsh-venice' && entry.paseo?.thinking == null)));
}

export function sessionOptionsFrom(table) {
  const aliases = table?.aliases ?? {};
  const manualProfiles = new Set(table?.dispatch?.manual_profiles ?? []);
  const paidRoute = (profile) => ['hermes-claude-api', 'dsh-venice'].includes(profile.harness);
  const choices = Object.entries(table?.profiles ?? {})
    .filter(([id, profile]) => profile && !Object.hasOwn(aliases, id) &&
      (profile.manual !== true || (!paidRoute(profile) && manualProfiles.has(id)) || manualEntranceExists(table, profile)))
    .filter(([, profile]) => ['claude', 'codex', 'dsh', 'dsh-venice', 'hermes-claude-api'].includes(profile.harness) &&
      (!paidRoute(profile) || profile.manual === true) && typeof profile.effort === 'string');
  const automaticIds = choices.filter(([, profile]) => profile.manual !== true).map(([id]) => id);
  // Existing clients fall back to the first item when defaultProfile is null.
  // Fail closed if HQ has no automatic choice, rather than selecting a manual one.
  const profiles = (automaticIds.length ? choices : [])
    .map(([id, profile]) => {
      const model = table.models?.[profile.model] ?? {};
      return {
        id,
        label: (model.label ?? profile.model) + (profile.harness === 'hermes-claude-api' ? '（API）' : profile.harness === 'dsh-venice' ? '（Venice）' : ''),
        provider: profile.harness,
        model: ['dsh', 'dsh-venice'].includes(profile.harness) ? JSON.stringify([profile.harness === 'dsh' ? 'opencode-go' : 'venice', model.modelId ?? profile.model])
          : (profile.harness === 'hermes-claude-api' ? 'anthropic:' : '') + (model.modelId ?? profile.model),
        effort: profile.effort,
        fast: fastSupported(profile.harness, model.modelId),
      };
    });
  return {
    profiles,
    switchProfiles: entranceProfiles(table, profiles),
    defaultProfile: automaticIds.includes(DEFAULT_PROFILE) ? DEFAULT_PROFILE : (automaticIds[0] ?? null),
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
