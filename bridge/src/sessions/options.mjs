// /v1/session-options — the model/effort choices the app offers for a new
// session, read from the HQ model table (hq/harness/models.json) that
// laa-personal-agent resolves profiles against. Reading the same file keeps the
// app from offering a profile the wrapper would refuse.

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { resolvePaseoBin } from '../config.mjs';
import { BridgeError } from '../errors.mjs';
import { providerAvailability, withAvailability } from './availability.mjs';
import { entranceProfiles, workRoute } from './entrance-profiles.mjs';

const DEFAULT_PROFILE = 'opus-high';
// The harnesses a Work session can run on; one that cannot run now keeps its place with the
// engine's reason on its label (availability.mjs). Antigravity is the Google AI Pro
// subscription (Sub2→Sub3→Sub4). Muse and Dots are not offered (2026-11-23: Work has no Muse
// CLI, and Dots did not answer a live turn in 300 s); their own employees keep them in Chat.
// Claude Code and Pi on their API keys (`claude-api`, `pi-openai-api`) are the same harnesses on
// a metered key; HQ's delegation entry runs them (personal_agent_bridge.mjs) when a manual Work
// entrance names the exact route (2026-11-26, the harness selector).
const WORK_HARNESSES = ['claude', 'codex', 'dsh', 'dsh-venice', 'hermes-claude-api', 'hermes-openai-api', 'antigravity',
  'claude-api', 'pi-openai-api'];
// Metered API routes: offered only by hand, with the route in the label, and marked `metered`
// so a client can say so without keeping its own list.
const PAID_ROUTES = { 'hermes-claude-api': { prefix: 'anthropic:', suffix: '（API）' },
  'hermes-openai-api': { prefix: 'openai-api:', suffix: '（API）' }, 'dsh-venice': { prefix: '', suffix: '（Venice）' },
  'claude-api': { prefix: '', suffix: '（API）' }, 'pi-openai-api': { prefix: '', suffix: '（API）' } };
// The model id a Work entrance and the launch body carry for a profile.
const DSH_ROUTES = { dsh: 'opencode-go', 'dsh-venice': 'venice', 'dsh-refuseless': 'refuseless' };
const SUBSCRIPTION_PROVIDERS = new Set(['claude', 'codex', 'antigravity', 'dsh']);
function wireModel(harness, modelId) {
  if (Object.hasOwn(DSH_ROUTES, harness)) return JSON.stringify([DSH_ROUTES[harness], modelId]);
  return (PAID_ROUTES[harness]?.prefix ?? '') + modelId;
}

// One reader of the engine's provider states for the live Bridge.
let shared = null;
export function sharedProviderAvailability() {
  if (shared === null) {
    let bin = null;
    try { bin = resolvePaseoBin(); } catch { bin = null; }
    shared = providerAvailability({ bin });
    void shared.refresh();
  }
  return shared;
}

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
  const wire = profile.harness === 'dsh' ? modelId : wireModel(profile.harness, modelId);
  return typeof modelId === 'string' && (table.entrances ?? []).some((entry) => {
    const route = workRoute(entry);
    return entry.status === 'manual' && route?.provider === profile.harness && expandModelId(table, route.model) === wire &&
      (route.thinking === profile.effort || (['dsh-venice', 'dsh-refuseless'].includes(profile.harness) && route.thinking == null));
  });
}

// HQ chooses what is visible. Route/model ids and existing profile ids remain
// the launch contract; display harness ids need not equal the provider id.
function pickerOptions(table, availability) {
  const picker = table.picker;
  const harnesses = (Array.isArray(picker?.harnesses) ? picker.harnesses : [])
    .filter((row) => typeof row?.id === 'string' && typeof row.name === 'string' && Number.isFinite(row.order))
    .map(({ id, name, order, kind }) => ({ id, name, order, kind: kind ?? id }))
    .sort((a, b) => a.order - b.order);
  const knownHarnesses = new Set(harnesses.map((row) => row.id));
  const chatHarness = harnesses.find(({ id }) => id === 'hermes');
  const profiles = new Map();
  const models = [];
  const chatModels = new Map();
  const defaultProfile = picker?.defaultProfile;
  let validDefault = false;
  for (const row of Array.isArray(picker?.models) ? picker.models : []) {
    const { harnessId, model, defaultEffort, surfaces } = row ?? {};
    const modelId = table.models?.[model]?.modelId;
    if (!knownHarnesses.has(harnessId) || typeof modelId !== 'string' || !Array.isArray(row.profiles)
      || !Array.isArray(surfaces) || !surfaces.some((surface) => surface === 'session' || surface === 'chat')) continue;
    const choices = [];
    const efforts = new Set();
    for (const id of row.profiles) {
      const profile = table.profiles?.[id];
      if (profile?.model !== model || Object.hasOwn(table.aliases ?? {}, id) || typeof profile.effort !== 'string') continue;
      const { harness: provider, effort } = profile;
      const first = choices[0];
      if (typeof provider !== 'string' || (first && first.provider !== provider) || efforts.has(effort)) continue;
      const wire = wireModel(provider, modelId);
      // Refuseless remains an opt-in manual route with an exact HQ entrance.
      const metered = provider === 'dsh-refuseless';
      if (metered && !(profile.manual === true && manualEntranceExists(table, profile))) continue;
      choices.push(withAvailability({ id, label: table.models[model].label ?? modelId, provider,
        model: wire, effort, fast: fastSupported(provider, modelId), ...(metered ? { manual: true, metered: true } : {}) },
      availability?.(provider) ?? null));
      efforts.add(effort);
    }
    if (!efforts.has(defaultEffort)) continue;
    if (surfaces.includes('session')) {
      for (const choice of choices) profiles.set(choice.id, choice);
      validDefault ||= choices.some(({ id, effort }) => id === defaultProfile && effort === defaultEffort && table.profiles[id].manual !== true);
    }
    const first = choices[0];
    const effectiveHarnessId = first.harness && first.harness !== first.provider && knownHarnesses.has(first.harness)
      ? first.harness : harnessId;
    models.push({ harnessId: effectiveHarnessId, provider: first.provider, model: first.model, label: first.label,
      ...('harness' in first ? { harness: first.harness } : {}),
      ...(first.available === false ? { available: false, unavailableReason: first.unavailableReason } : {}),
      ...('fastHarness' in first ? { fastHarness: first.fastHarness } : {}),
      ...(first.metered ? { metered: true, manual: true } : {}),
      efforts: [...efforts], defaultEffort, profiles: choices.map((choice) => choice.id), surfaces });
    const { provider } = first;
    if (!chatHarness || !surfaces.includes('chat') || !SUBSCRIPTION_PROVIDERS.has(provider)) continue;
    const chatProvider = table.employees?.providers?.[provider] ?? (provider === 'dsh' ? 'laa-dsh' : null);
    if (typeof chatProvider !== 'string' || !chatProvider) continue;
    // DSH's two Session groups share one Hermes route. Chat availability comes
    // from Hermes, not the Work provider state used by the Session catalog.
    const key = JSON.stringify([chatProvider, modelId]);
    if (!chatModels.has(key)) chatModels.set(key, { harnessId: chatHarness.id,
      provider, model: first.model, chatProvider, chatModel: modelId, label: table.models[model].label ?? modelId,
      efforts: [...efforts], defaultEffort });
  }
  const published = validDefault ? [...profiles.values()] : [];
  const usedHarnesses = new Set(models.flatMap((row) => [row.harnessId, row.fastHarness]));
  return { profiles: published, switchProfiles: entranceProfiles(table, published),
    defaultProfile: validDefault ? defaultProfile : null, defaultMode: 'bypass',
    harnesses: validDefault ? harnesses.filter((row) => usedHarnesses.has(row.id)) : [], models: validDefault ? models : [],
    chat: { harnesses: validDefault && chatModels.size ? [chatHarness] : [], models: validDefault ? [...chatModels.values()] : [] } };
}

export function sessionOptionsFrom(table, availability = null) {
  if (Object.hasOwn(table ?? {}, 'picker')) return pickerOptions(table, availability);
  const aliases = table?.aliases ?? {};
  const manualProfiles = new Set(table?.dispatch?.manual_profiles ?? []);
  const paidRoute = (profile) => Object.hasOwn(PAID_ROUTES, profile.harness);
  const choices = Object.entries(table?.profiles ?? {})
    .filter(([id, profile]) => profile && !Object.hasOwn(aliases, id) &&
      (profile.manual !== true || (!paidRoute(profile) && manualProfiles.has(id)) || manualEntranceExists(table, profile)))
    .filter(([, profile]) => WORK_HARNESSES.includes(profile.harness) &&
      (!paidRoute(profile) || profile.manual === true) && typeof profile.effort === 'string');
  const automaticIds = choices.filter(([, profile]) => profile.manual !== true).map(([id]) => id);
  // Existing clients fall back to the first item when defaultProfile is null.
  // Fail closed if HQ has no automatic choice, rather than selecting a manual one.
  const profiles = (automaticIds.length ? choices : [])
    .map(([id, profile]) => {
      const model = table.models?.[profile.model] ?? {};
      return withAvailability({
        id,
        label: (model.label ?? profile.model) + (PAID_ROUTES[profile.harness]?.suffix ?? ''),
        provider: profile.harness,
        model: wireModel(profile.harness, model.modelId ?? profile.model),
        effort: profile.effort,
        fast: fastSupported(profile.harness, model.modelId),
        ...(paidRoute(profile) ? { metered: true } : {}),
      }, availability?.(profile.harness) ?? null);
    });
  return {
    profiles,
    switchProfiles: entranceProfiles(table, profiles),
    defaultProfile: automaticIds.includes(DEFAULT_PROFILE) ? DEFAULT_PROFILE : (automaticIds[0] ?? null),
    defaultMode: 'bypass',
  };
}

// `availability` is the engine's provider states (sharedProviderAvailability) or null.
export function sessionOptionsReader({ file = resolveModelsFile(), availability = null, requirePicker = false } = {}) {
  const readTable = () => {
    let table;
    try {
      table = JSON.parse(readFileSync(file, 'utf8'));
    } catch {
      throw new BridgeError(503, 'options_unavailable', 'the model table cannot be read', { retryable: true });
    }
    if (requirePicker && !Object.hasOwn(table ?? {}, 'picker')) {
      throw new BridgeError(503, 'options_unavailable', 'the HQ model picker is missing', { retryable: true });
    }
    return table;
  };
  const readOptions = () => {
    const options = sessionOptionsFrom(readTable(), availability ? (provider) => availability.get(provider) : null);
    if (options.profiles.length === 0) {
      throw new BridgeError(503, 'options_unavailable', 'the model table lists no usable profile', { retryable: true });
    }
    return options;
  };
  // Previously saved pins may use efforts hidden by the new picker. This is
  // deliberately not serialized or used to validate new project defaults.
  readOptions.retainedProfile = (id) => {
    const table = readTable();
    const profile = table?.profiles?.[id];
    if (!table?.picker || !profile || Object.hasOwn(table.aliases ?? {}, id)
      || !SUBSCRIPTION_PROVIDERS.has(profile.harness) || typeof profile.effort !== 'string') return null;
    const model = table.models?.[profile.model];
    if (typeof model?.modelId !== 'string') return null;
    return withAvailability({ id, provider: profile.harness, model: wireModel(profile.harness, model.modelId),
      effort: profile.effort }, availability?.get(profile.harness) ?? null);
  };
  return readOptions;
}
