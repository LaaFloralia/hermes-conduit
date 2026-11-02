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
    'deepseek-flash-high': { model: 'flash', harness: 'dsh', effort: 'high' },
  },
  aliases: { 'astra-high': 'sol-xhigh' },
  models: {
    opus: { label: 'Claude Opus 5.5', modelId: 'claude-opus-5-5' },
    sonnet: { label: 'Claude Sonnet 5.5', modelId: 'claude-sonnet-5-5' },
    terra: { label: 'GPT-6.1 Terra', modelId: 'gpt-6.1-terra' },
    astra: { label: 'GPT-6 Astra', modelId: 'gpt-6-astra' },
    flash: { label: 'DeepSeek V4.1-Flash-1017', modelId: 'deepseek-v4.1-flash' },
  },
};

test('options list usable profiles in file order, skip manual and alias names, and mark fast', () => {
  const options = sessionOptionsFrom(table);
  assert.deepEqual(options.profiles.map((item) => [item.id, item.fast]), [
    ['opus-high', true], ['sonnet-high', false], ['sol-high', true], ['deepseek-flash-high', false],
  ]);
  assert.equal(options.profiles[0].label, 'Claude Opus 5.5');
  assert.equal(options.defaultProfile, 'opus-high');
  assert.equal(options.defaultMode, 'bypass');
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
  assert.equal(ok.body.data.profiles.length, 4);
  rmSync(file);
  const down = await bridge.request('/v1/session-options', { token });
  assert.equal(down.status, 503);
  assert.equal(down.body.error.code, 'options_unavailable');
});
