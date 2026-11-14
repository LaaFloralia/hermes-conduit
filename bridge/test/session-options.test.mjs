import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { daemonAdapter } from '../src/sessions/daemon.mjs';
import { sessionOptionsFrom } from '../src/sessions/options.mjs';
import { startBridge } from './helpers.mjs';

const table = {
  profiles: {
    'opus-high': { model: 'opus', harness: 'claude', effort: 'high' },
    'sonnet-high': { model: 'sonnet', harness: 'claude', effort: 'high' },
    'sol-high': { model: 'terra', harness: 'codex', effort: 'high' },
    'astra-high': { model: 'terra', harness: 'codex', effort: 'xhigh' },
    'astra-max': { model: 'astra', harness: 'codex', effort: 'max', manual: true },
    'fable-high': { model: 'fable', harness: 'claude', effort: 'high', manual: true },
    'deepseek-flash-high': { model: 'flash', harness: 'dsh', effort: 'high' },
  },
  aliases: { 'astra-high': 'sol-xhigh' },
  models: {
    opus: { label: 'Claude Opus 5.5', modelId: 'claude-opus-5-5' },
    sonnet: { label: 'Claude Sonnet 5.5', modelId: 'claude-sonnet-5-5' },
    terra: { label: 'GPT-6.1 Terra', modelId: 'gpt-6.1-terra' },
    astra: { label: 'GPT-6 Astra', modelId: 'gpt-6-astra' },
    fable: { label: 'Claude Fable 5.2', modelId: 'claude-fable-5-2' },
    flash: { label: 'DeepSeek V4.1-Flash-1017', modelId: 'deepseek-v4.1-flash' },
  },
  entrances: [{ kind: 'paseo', status: 'manual', paseo: { provider: 'claude', model: 'claude-fable-5-2', thinking: 'high' } }],
};

test('options expose explicit manual Work entrances, skip other manual profiles and aliases, and mark fast', () => {
  const options = sessionOptionsFrom(table);
  assert.deepEqual(options.profiles.map((item) => [item.id, item.fast]), [
    ['opus-high', true], ['sonnet-high', false], ['sol-high', true], ['fable-high', false], ['deepseek-flash-high', false],
  ]);
  assert.equal(options.profiles[0].label, 'Claude Opus 5.5');
  assert.equal(options.defaultProfile, 'opus-high');
  assert.equal(options.defaultMode, 'bypass');
});

test('manual profile requires a matching manual provider, model and effort', () => {
  const fable = table.entrances[0];
  const offered = (entry) => sessionOptionsFrom({ ...table, entrances: [entry] }).profiles.some((p) => p.id === 'fable-high');
  assert.equal(offered(fable), true);
  for (const changed of [
    { ...fable, kind: 'product' },
    { ...fable, status: 'stopped' },
    { ...fable, status: 'active' },
    { ...fable, paseo: { ...fable.paseo, provider: 'codex' } },
    { ...fable, paseo: { ...fable.paseo, model: 'claude-fable-5-1' } },
    { ...fable, paseo: { ...fable.paseo, thinking: 'max' } },
  ]) assert.equal(offered(changed), false);
});

test('a manual entrance written as an HQ id template is offered; an unknown template is not', () => {
  const fable = table.entrances[0];
  const offered = (model) => sessionOptionsFrom({ ...table, entrances: [{ ...fable, paseo: { ...fable.paseo, model } }] })
    .profiles.some((p) => p.id === 'fable-high');
  assert.equal(offered('{{id:fable}}'), true);
  assert.equal(offered('{{id:missing}}'), false);
  assert.equal(offered('{{id:sonnet}}'), false);
});

test('manual profiles never become the automatic default or the sole fallback', () => {
  const onlyFable = { 'fable-high': table.profiles['fable-high'] };
  const noAutomatic = sessionOptionsFrom({ ...table, profiles: onlyFable });
  assert.deepEqual(noAutomatic.profiles, []);
  assert.equal(noAutomatic.defaultProfile, null);
  const fallback = sessionOptionsFrom({ ...table, profiles: { ...onlyFable, 'sonnet-high': table.profiles['sonnet-high'] } });
  assert.equal(fallback.defaultProfile, 'sonnet-high');
  assert.deepEqual(fallback.profiles.map((p) => p.id), ['fable-high', 'sonnet-high']);
});

test('Claude API choices retain their paid route and require an explicit manual entrance', () => {
  const api = { ...table, profiles: { ...table.profiles,
    'fable-api-high': { model: 'fable', harness: 'hermes-claude-api', effort: 'high', manual: true },
  }, entrances: [...table.entrances, { kind: 'paseo', status: 'manual', paseo: {
    provider: 'hermes-claude-api', model: 'anthropic:{{id:fable}}', thinking: 'high',
  } }] };
  const options = sessionOptionsFrom(api);
  assert.deepEqual(options.profiles.find(p => p.id === 'fable-api-high'), {
    id: 'fable-api-high', label: 'Claude Fable 5.2（API）', provider: 'hermes-claude-api',
    model: 'anthropic:claude-fable-5-2', effort: 'high', fast: false,
  });
  assert.equal(options.defaultProfile, 'opus-high');
  api.entrances.at(-1).status = 'stopped';
  assert.ok(!sessionOptionsFrom(api).profiles.some(p => p.id === 'fable-api-high'));
  api.entrances.at(-1).status = 'manual';
  api.profiles['fable-api-high'].manual = false;
  assert.ok(!sessionOptionsFrom(api).profiles.some(p => p.id === 'fable-api-high'));
});

test('GET /v1/session-options reads the model table and fails closed when it is missing', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-bridge-options-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, 'models.json');
  writeFileSync(file, JSON.stringify(table));
  const bridge = await startBridge({ sessions: { modelsFile: file } });
  t.after(() => bridge.close());
  const token = await bridge.token();
  const ok = await bridge.request('/v1/session-options', { token });
  assert.equal(ok.status, 200);
  assert.equal(ok.body.data.profiles.length, 5);
  assert.ok(ok.body.data.profiles.some((profile) => profile.id === 'fable-high'));
  rmSync(file);
  const down = await bridge.request('/v1/session-options', { token });
  assert.equal(down.status, 503);
  assert.equal(down.body.error.code, 'options_unavailable');
});

test('the options carry the efforts Paseo lists per model; a provider it cannot list is left out', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-bridge-options-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, 'models.json');
  writeFileSync(file, JSON.stringify(table));
  const asked = [];
  const client = {
    close: async () => {},
    getLastServerInfoMessage: () => ({ features: {} }),
    listProviderModels: async (provider) => {
      asked.push(provider);
      if (provider === 'codex') throw new Error('provider is not signed in');
      if (provider === 'dsh') return { models: [{ id: 'flash', thinkingOptions: [] }, { id: 7 }] };
      return { models: [
        { id: 'claude-fable-5-2', thinkingOptions: [{ id: 'low' }, { id: 'high', isDefault: true }, { id: 'max' }, { id: '' }, {}] },
        { id: 'claude-opus-5-5', thinkingOptions: [{ id: 'medium' }, { id: 'high' }] },
      ] };
    },
  };
  let clock = 1000;
  const daemon = daemonAdapter({ connect: async () => client, now: () => clock });
  const bridge = await startBridge({ sessions: { modelsFile: file, daemon } });
  t.after(() => bridge.close());
  const token = await bridge.token();
  const first = await bridge.request('/v1/session-options', { token });
  assert.equal(first.status, 200);
  assert.equal(first.body.data.profiles.length, 5);
  assert.deepEqual(first.body.data.efforts, [
    { provider: 'claude', model: 'claude-fable-5-2', efforts: ['low', 'high', 'max'] },
    { provider: 'claude', model: 'claude-opus-5-5', efforts: ['medium', 'high'] },
  ]);
  // Within a minute Paseo is not asked again for a provider it answered.
  await bridge.request('/v1/session-options', { token });
  assert.equal(asked.filter((provider) => provider === 'claude').length, 1);
  clock += 61_000;
  await bridge.request('/v1/session-options', { token });
  assert.equal(asked.filter((provider) => provider === 'claude').length, 2);
});

test('without Paseo the options list no efforts and still answer', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-bridge-options-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, 'models.json');
  writeFileSync(file, JSON.stringify(table));
  const bridge = await startBridge({ sessions: { modelsFile: file } });
  t.after(() => bridge.close());
  const reply = await bridge.request('/v1/session-options', { token: await bridge.token() });
  assert.equal(reply.status, 200);
  assert.deepEqual(reply.body.data.efforts, []);
});

test('named manual dispatch profiles expose Max and Ultra Code without replacing the automatic default', () => {
  const extended = { ...table, profiles: { ...table.profiles,
    'fable-max': { model: 'fable', harness: 'claude', effort: 'max', manual: true },
    'fable-ultracode': { model: 'fable', harness: 'claude', effort: 'ultracode', manual: true },
  }, dispatch: { manual_profiles: ['astra-max', 'fable-max', 'fable-ultracode'] } };
  const options = sessionOptionsFrom(extended);
  assert.equal(options.defaultProfile, 'opus-high');
  for (const id of extended.dispatch.manual_profiles) {
    assert.ok(options.profiles.some(p => p.id === id));
    assert.ok(options.switchProfiles.some(p => p.id === id));
  }
  assert.equal(options.profiles.find(p => p.id === 'astra-max').model, 'gpt-6-astra');
});

test('manual Venice DSH keeps its wire route and is never an automatic choice', () => {
  const venice = { ...table, profiles: { ...table.profiles,
    'uncensored-high': { model: 'uncensored', harness: 'dsh-venice', effort: 'high', manual: true },
    'uncensored-max': { model: 'uncensored', harness: 'dsh-venice', effort: 'max', manual: true },
  }, models: { ...table.models, uncensored: { modelId: 'deepseek-uncensored', label: 'DeepSeek Uncensored' } },
  dispatch: { manual_profiles: ['uncensored-high', 'uncensored-max'] },
  entrances: [{ kind: 'paseo', status: 'manual', paseo: {
    provider: 'dsh-venice', model: '["venice","{{id:uncensored}}"]', thinking: null,
  } }] };
  const options = sessionOptionsFrom(venice);
  for (const id of venice.dispatch.manual_profiles) {
    const p = options.profiles.find(p => p.id === id);
    assert.equal(p.provider, 'dsh-venice');
    assert.equal(p.model, '["venice","deepseek-uncensored"]');
    assert.equal(p.fast, false);
  }
  assert.equal(options.defaultProfile, 'opus-high');
  venice.entrances[0].status = 'stopped';
  assert.ok(!sessionOptionsFrom(venice).profiles.some(p => p.provider === 'dsh-venice'));
});

test('HTTP launch catalog does not call provider discovery; full options still do', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-bridge-options-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, 'models.json');
  writeFileSync(file, JSON.stringify(table));
  let calls = 0;
  const daemon = { efforts: async () => {
    calls++;
    return [{ model: 'example', efforts: ['high'] }];
  } };
  const bridge = await startBridge({ sessions: { modelsFile: file, daemon } });
  t.after(() => bridge.close());
  const token = await bridge.token(['sessions:read']);
  for (let i = 0; i < 2; i++) {
    const fast = await bridge.request('/v1/session-options?catalogOnly=true', { token });
    assert.equal(fast.status, 200);
    assert.equal(calls, 0);
    assert.equal(fast.body.data.defaultProfile, 'opus-high');
    assert.deepEqual(fast.body.data.profiles, sessionOptionsFrom(table).profiles);
    assert.deepEqual(fast.body.data.efforts, []);
  }
  const full = await bridge.request('/v1/session-options', { token });
  assert.equal(full.status, 200);
  assert.ok(calls > 0);
  assert.equal(full.body.data.efforts.length, calls);
});

test('provider discovery coalesces cold calls, refreshes stale rows and backs off failures', async () => {
  let clock = 0, calls = 0, fail = false, release;
  let gate = new Promise(resolve => { release = resolve; });
  const client = { close: async () => {}, listProviderModels: async () => {
    calls++;
    await gate;
    if (fail) throw new Error('offline');
    return { models: [{ id: 'model', thinkingOptions: [{ id: 'max' }] }] };
  } };
  const adapter = daemonAdapter({ connect: async () => client, now: () => clock });
  const a = adapter.efforts('claude'), b = adapter.efforts('claude');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls, 1);
  release();
  assert.deepEqual(await a, await b);
  clock = 61_000;
  gate = new Promise(resolve => { release = resolve; });
  assert.deepEqual(await adapter.efforts('claude'), [{ model: 'model', efforts: ['max'] }]);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls, 2);
  fail = true; release();
  await new Promise(resolve => setImmediate(resolve));
  await adapter.efforts('claude');
  assert.equal(calls, 2);
});

test('new sessions forward explicit Max, Ultra Code and Venice profile keys unchanged', async (t) => {
  const calls = [];
  const requested = {
    'astra-max': { provider: 'codex', model: 'gpt-6-astra', effort: 'max' },
    'fable-ultracode': { provider: 'claude', model: 'claude-fable-5-2', effort: 'ultracode' },
    'uncensored-max': { provider: 'dsh-venice', model: '["venice","deepseek-uncensored"]', effort: 'max' },
  };
  const bridge = await startBridge({ sessions: { adapter: {
    create: async ({ profile }) => {
      calls.push(profile);
      return { sessionId: `fixture-${profile}`, requested: { profile, ...requested[profile] } };
    },
  } } });
  t.after(() => bridge.close());
  const token = await bridge.token();
  for (const profile of Object.keys(requested)) {
    const result = await bridge.request('/v1/sessions', { token, method: 'POST', key: `launch-${profile}`, body: {
      requestId: `launch-${profile}`, profile, prompt: 'fixture only', mode: 'bypass',
    } });
    assert.equal(result.status, 201);
    assert.equal(result.body.data.profile, profile);
    assert.deepEqual(result.body.data.requested, { profile, ...requested[profile] });
  }
  assert.deepEqual(calls, Object.keys(requested));
});
