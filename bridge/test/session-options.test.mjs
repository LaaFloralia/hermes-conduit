import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
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

test('manual profiles never become the automatic default or the sole fallback', () => {
  const onlyFable = { 'fable-high': table.profiles['fable-high'] };
  const noAutomatic = sessionOptionsFrom({ ...table, profiles: onlyFable });
  assert.deepEqual(noAutomatic.profiles, []);
  assert.equal(noAutomatic.defaultProfile, null);
  const fallback = sessionOptionsFrom({ ...table, profiles: { ...onlyFable, 'sonnet-high': table.profiles['sonnet-high'] } });
  assert.equal(fallback.defaultProfile, 'sonnet-high');
  assert.deepEqual(fallback.profiles.map((p) => p.id), ['fable-high', 'sonnet-high']);
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
