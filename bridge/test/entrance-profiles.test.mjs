import assert from 'node:assert/strict';
import test from 'node:test';
import { entranceProfiles } from '../src/sessions/entrance-profiles.mjs';

const profiles = [
  { id: 'sol-high', provider: 'codex', model: 'sol', effort: 'high' },
  { id: 'sol-low', provider: 'codex', model: 'sol', effort: 'low' },
  { id: 'unlisted-high', provider: 'codex', model: 'unlisted', effort: 'high' },
  { id: 'dsh-high', provider: 'dsh', model: '["opencode-go","flash"]', effort: 'high' },
  { id: 'dsh-max', provider: 'dsh', model: '["opencode-go","flash"]', effort: 'max' },
  { id: 'api-high', provider: 'hermes-claude-api', model: 'anthropic:fable', effort: 'high' },
];
const entry = (provider, model, thinking, status = 'active') => ({ kind: 'paseo', status, paseo: { provider, model, thinking } });
test('switch catalog intersects entrances, exact provider/wire model and effort, without changing launch defaults', () => {
  const table = { models: { sol: { modelId: 'sol' }, flash: { modelId: 'flash' }, fable: { modelId: 'fable' } }, entrances: [
    entry('codex', '{{id:sol}}', 'high'), entry('dsh', '["opencode-go","{{id:flash}}"]', null),
    entry('hermes-claude-api', 'anthropic:{{id:fable}}', 'high', 'manual'),
  ] };
  assert.deepEqual(entranceProfiles(table, profiles).map((p) => p.id), ['sol-high', 'dsh-high', 'dsh-max', 'api-high']);
  assert.equal(profiles.length, 6, 'the original launch catalog is unchanged');
});
test('stopped, other-product, unknown-template and other-provider entrances grant no switch', () => {
  for (const bad of [
    entry('codex', 'sol', 'high', 'stopped'),
    { ...entry('codex', 'sol', 'high'), kind: 'product' },
    entry('codex', '{{id:missing}}', 'high'), entry('claude', 'sol', 'high'),
  ]) assert.deepEqual(entranceProfiles({ entrances: [bad] }, profiles), []);
});
