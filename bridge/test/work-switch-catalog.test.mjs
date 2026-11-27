import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { sessionOptionsReader } from '../src/sessions/options.mjs';
import { createModelSwitcher } from '../src/sessions/model-switch.mjs';
import { createSessionService } from '../src/sessions/service.mjs';
import { createProjectRoutes } from '../src/routes/projects.mjs';

function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'switch-catalog-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const table = {
    profiles: {
      'opus-high': { model: 'opus', harness: 'claude', effort: 'high' },
      'sol-high': { model: 'sol', harness: 'codex', effort: 'high' },
      'sol-low': { model: 'sol', harness: 'codex', effort: 'low' },
      'unlisted-high': { model: 'unlisted', harness: 'codex', effort: 'high' },
      'dsh-high': { model: 'flash', harness: 'dsh', effort: 'high' },
      'fable-api-high': { model: 'fable', harness: 'hermes-claude-api', effort: 'high', manual: true },
    }, models: Object.fromEntries(['opus', 'sol', 'unlisted', 'flash', 'fable'].map((key) => [key, { modelId: key, label: key }])),
    entrances: [
      { kind: 'paseo', status: 'active', paseo: { provider: 'claude', model: '{{id:opus}}', thinking: 'high' } },
      { kind: 'paseo', status: 'active', paseo: { provider: 'codex', model: '{{id:sol}}', thinking: 'high' } },
      { kind: 'paseo', status: 'active', paseo: { provider: 'dsh', model: '["opencode-go","{{id:flash}}"]', thinking: null } },
      { kind: 'paseo', status: 'manual', paseo: { provider: 'hermes-claude-api', model: 'anthropic:{{id:fable}}', thinking: 'high' } },
    ],
  };
  const file = join(dir, 'models.json'); writeFileSync(file, JSON.stringify(table));
  return sessionOptionsReader({ file });
}

test('provider catalog keeps explicit API choices and the DSH wire model distinct', (t) => {
  const data = fixture(t)();
  assert.deepEqual([...new Set(data.profiles.map((p) => p.provider))], ['claude', 'codex', 'dsh', 'hermes-claude-api']);
  assert.equal(data.profiles.find((p) => p.provider === 'dsh').model, '["opencode-go","flash"]');
  assert.equal(data.profiles.find((p) => p.provider === 'hermes-claude-api').model, 'anthropic:fable');
});
test('app switch choices are only exact entrances; legacy launch options remain separate', (t) => {
  const choices = fixture(t), data = choices();
  assert.deepEqual(data.switchProfiles.map((p) => p.id), ['opus-high', 'sol-high', 'dsh-high', 'fable-api-high']);
  assert.ok(data.profiles.some((p) => p.id === 'unlisted-high'));
  const switcher = createModelSwitcher({ choices });
  assert.throws(() => switcher.choice({ provider: 'codex', model: 'unlisted', effort: 'high' }, {}), { code: 'model_choice_invalid' });
});
test('new switch catalog does not change the automatic default or default permission mode', (t) => {
  const data = fixture(t)();
  assert.equal(data.defaultProfile, 'opus-high');
  assert.equal(data.defaultMode, 'bypass');
});
test('project defaults cannot select or silently inherit a legacy profile outside entrances', async (t) => {
  const choices = fixture(t);
  const routes = createProjectRoutes({ projects: {}, choices });
  const create = routes.find((r) => r.method === 'POST' && r.path === '/v1/projects');
  assert.throws(() => create.handler({ rawBody: JSON.stringify({ name: 'same', defaultProfile: 'unlisted-high' }) }), { code: 'model_choice_invalid' });
  const service = createSessionService({ choices, sessionStore: { file: join(tmpdir(), 'unused-session-state.json') },
    adapter: { create: () => assert.fail('must not launch a substitute') },
    findProject: () => ({ id: 'project', defaultProfile: 'unlisted-high' }) });
  t.after(() => service.close());
  await assert.rejects(service.createSession({ deviceId: 'probe', body: { requestId: 'obsolete-default',
    prompt: 'do not start', projectId: 'project' } }), { code: 'project_default_unavailable' });
});
