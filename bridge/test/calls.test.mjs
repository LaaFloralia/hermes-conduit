import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startBridge } from './helpers.mjs';
import { resolveCallEngines } from '../src/routes/calls.mjs';

const endpoint = '/v1/calls/engine';
const waiting = {
  enabled: false,
  code: 'waiting_for_contract',
  reason: 'waiting for the Google AI Ultra contract / Gemini API key',
  reasonJa: 'Google AI Ultraの契約とGemini APIキーを待っています',
};

function files(t) {
  const dir = mkdtempSync(join(tmpdir(), 'laa-calls-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return { file: join(dir, 'staff-call-engine.json'), hermesEnvFile: join(dir, 'hermes-personal.env.tpl') };
}

test('call engine needs device auth and sessions:read', async (t) => {
  const bridge = await startBridge({ calls: files(t) });
  t.after(() => bridge.close());
  assert.equal((await bridge.request(endpoint)).status, 401);
  assert.equal((await bridge.request(endpoint, { token: await bridge.token(['brain:read']) })).status, 403);
  assert.equal((await bridge.request(endpoint, { token: await bridge.token(['sessions:read']) })).status, 200);
});

test('with no file a call runs on Local Live and Gemini Live waits for the contract', async (t) => {
  const bridge = await startBridge({ calls: files(t) });
  t.after(() => bridge.close());
  const response = await bridge.request(endpoint, { token: await bridge.token() });
  assert.deepEqual(response.body.data, {
    engine: 'local_live',
    order: ['gemini_live', 'local_live'],
    engines: { local_live: { enabled: true }, gemini_live: waiting },
    source: 'default',
  });
});

test('a key reference alone does not switch Gemini Live on', async (t) => {
  const paths = files(t);
  writeFileSync(paths.hermesEnvFile, 'GEMINI_API_KEY=op://Agents/Gemini API LAA/credential\n');
  const bridge = await startBridge({ calls: paths });
  t.after(() => bridge.close());
  const { data } = (await bridge.request(endpoint, { token: await bridge.token() })).body;
  assert.equal(data.engine, 'local_live');
  assert.deepEqual(data.engines.gemini_live, waiting);
});

test('the switch alone does not turn Gemini Live on without the key reference', async (t) => {
  const paths = files(t);
  writeFileSync(paths.file, JSON.stringify({ gemini_live: { enabled: true } }));
  writeFileSync(paths.hermesEnvFile, 'OPENCODE_GO_API_KEY=op://Agents/Other/credential\n# GEMINI_API_KEY=\nGEMINI_API_KEY=\n');
  const bridge = await startBridge({ calls: paths });
  t.after(() => bridge.close());
  const { data } = (await bridge.request(endpoint, { token: await bridge.token() })).body;
  assert.equal(data.engine, 'local_live');
  assert.equal(data.source, 'file');
  assert.equal(data.engines.gemini_live.enabled, false);
  assert.equal(data.engines.gemini_live.code, 'key_reference_missing');
});

test('the switch and the key reference together move calls to Gemini Live without a restart', async (t) => {
  const paths = files(t);
  const bridge = await startBridge({ calls: paths });
  t.after(() => bridge.close());
  const token = await bridge.token();
  assert.equal((await bridge.request(endpoint, { token })).body.data.engine, 'local_live');
  writeFileSync(paths.file, JSON.stringify({ gemini_live: { enabled: true } }));
  writeFileSync(paths.hermesEnvFile, 'export GEMINI_API_KEY = op://Agents/Gemini API LAA/credential\n');
  const { data } = (await bridge.request(endpoint, { token })).body;
  assert.deepEqual(data, {
    engine: 'gemini_live',
    order: ['gemini_live', 'local_live'],
    engines: { local_live: { enabled: true }, gemini_live: { enabled: true } },
    source: 'file',
  });
  // The response carries configuration only, never the reference or a value.
  assert.doesNotMatch(JSON.stringify(data), /op:\/\/|credential/);
});

test('the file can put Local Live first or switch an engine off', () => {
  const both = resolveCallEngines({ order: ['local_live', 'gemini_live'], gemini_live: { enabled: true } }, { keyReference: true });
  assert.equal(both.engine, 'local_live');
  assert.deepEqual(both.order, ['local_live', 'gemini_live']);
  const none = resolveCallEngines({ local_live: { enabled: false } });
  assert.equal(none.engine, null);
  assert.equal(none.engines.local_live.code, 'switched_off');
  const geminiOnly = resolveCallEngines({ local_live: { enabled: false }, gemini_live: { enabled: true } }, { keyReference: true });
  assert.equal(geminiOnly.engine, 'gemini_live');
});

test('unknown names, repeats and wrong types keep the defaults', () => {
  for (const config of [null, [], 'gemini_live', { order: 'gemini_live' }, { order: ['gpt_live', 'gpt_live', 7] },
    { gemini_live: true }, { gemini_live: { enabled: 'yes' } }, { gemini_live: { enabled: 1 } }]) {
    const resolved = resolveCallEngines(config, { keyReference: true });
    assert.equal(resolved.engine, 'local_live');
    assert.deepEqual(resolved.order, ['gemini_live', 'local_live']);
    assert.equal(resolved.engines.gemini_live.code, 'waiting_for_contract');
  }
  assert.deepEqual(resolveCallEngines({ order: ['local_live', 'local_live'] }).order, ['local_live', 'gemini_live']);
});

test('a malformed file falls back to the defaults and warns once per read', async (t) => {
  const paths = files(t);
  writeFileSync(paths.file, '{ not json');
  const events = [];
  const bridge = await startBridge({ calls: paths, log: (entry) => events.push(entry) });
  t.after(() => bridge.close());
  const { data } = (await bridge.request(endpoint, { token: await bridge.token() })).body;
  assert.equal(data.engine, 'local_live');
  assert.equal(data.source, 'default');
  assert.deepEqual(events.filter((entry) => entry.event === 'staff_call_engine_unreadable'),
    [{ level: 'warn', event: 'staff_call_engine_unreadable' }]);
});
