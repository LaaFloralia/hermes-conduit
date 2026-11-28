import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { IDEMPOTENCY_RETENTION_MS, PAIRING_TTL_MS } from '../src/config.mjs';
import { createBridge } from '../src/http.mjs';
import { laneClient } from '../src/lane/client.mjs';
import { issuePairing } from '../src/pairing.mjs';
import { sessionOptionsFrom, sessionOptionsReader } from '../src/sessions/options.mjs';
import { createSessionService } from '../src/sessions/service.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { createStore } from '../src/store.mjs';
import { clearInheritedAdapters, startBridge } from './helpers.mjs';

const profile = (harness, model, effort = 'high', manual = false) => ({ harness, model, effort, manual });
const group = (id, name, order) => ({ id, name, order });
const model = (harnessId, model, profiles, defaultEffort, surfaces = ['session', 'chat']) => ({ harnessId, model, profiles, defaultEffort, surfaces });
const opus = 'claude-opus-5-5', sol = 'gpt-6.2-sol', flash = 'deepseek-v4.1-flash', uncensored = 'deepseek-v4.1-flash-abliterated-fast';
const go = JSON.stringify(['opencode-go', flash]), refused = JSON.stringify(['refuseless', uncensored]);
const goGroups = ['dsh-orchestrator', 'dsh-worker'];
const hermesProviders = { claude: 'claude-subscription-directsdk-experimental', codex: 'openai-codex', antigravity: 'laa-agy', dsh: 'laa-dsh' };
const fixture = {
  employees: { providers: { claude: hermesProviders.claude, codex: hermesProviders.codex } },
  models: Object.fromEntries([opus, sol, uncensored, 'claude-opus-5', 'gpt-6.1-sol', 'gpt-6-luna', flash].map((id) =>
    [id, { modelId: id, label: id }])),
  profiles: {
    'opus-medium': profile('claude', opus, 'medium'), 'opus-high': profile('claude', opus),
    'sol-medium': profile('codex', sol, 'medium'), 'sol-high': profile('codex', sol),
    'opus-xhigh': profile('claude', opus, 'xhigh', true),
    'old-opus': profile('claude', 'claude-opus-5'), 'old-sol': profile('codex', 'gpt-6.1-sol'),
    'luna-high': profile('codex', 'gpt-6-luna'), 'deepseek-flash-high': profile('dsh', flash), 'deepseek-flash-max': profile('dsh', flash, 'max'),
    'gpt-api-high': profile('pi-openai-api', sol, 'high', true), 'claude-api-high': profile('claude-api', opus, 'high', true),
    'uncensored-high': profile('dsh-refuseless', uncensored, 'high', true),
  },
  entrances: [
    { status: 'active', kind: 'work', work: { provider: 'claude', model: '{{id:claude-opus-5-5}}', thinking: 'medium' } },
    { status: 'active', kind: 'work', work: { provider: 'codex', model: '{{id:gpt-6.2-sol}}', thinking: 'medium' } },
    { status: 'active', kind: 'work', work: { provider: 'dsh', model: `["opencode-go","{{id:${flash}}}"]` } },
    { status: 'manual', kind: 'work', work: { provider: 'dsh-refuseless', model: `["refuseless","{{id:${uncensored}}}"]` } },
  ],
  dispatch: { manual_profiles: ['gpt-api-high', 'claude-api-high', 'uncensored-high'] },
  picker: {
    defaultProfile: 'opus-medium',
    harnesses: [group('hermes', 'Hermes', 0), group('codex', 'Codex', 20), group('pi', 'Pi', 30), group('dsh-refuseless', 'Refuseless', 50), group('claude', 'Claude Code', 10),
      group('dsh-orchestrator', 'DSH Orchestrator', 35), group('dsh-worker', 'DSH Worker', 40)],
    models: [model('claude', opus, ['opus-medium'], 'medium'), model('codex', sol, ['sol-medium'], 'medium'),
      ...goGroups.map((id) => model(id, flash, ['deepseek-flash-high', 'deepseek-flash-max'], 'high')),
      model('dsh-refuseless', uncensored, ['uncensored-high'], 'high', ['session'])],
  },
};

test('HQ Codex rows project Pi and Codex Fast without changing wire routes or Chat', () => {
  const stage = process.env.D23_STAGE_HQ_MODELS;
  const table = stage ? JSON.parse(readFileSync(stage, 'utf8')) : fixture;
  const anchored = sessionOptionsFrom(table);
  const moved = sessionOptionsFrom(table, (provider) => provider === 'codex' ? { harness: 'pi', available: true } : null);
  const gptIds = stage ? [sol, 'gpt-6.2-astra', 'gpt-6.1-terra'] : [sol];
  assert.deepEqual(moved.harnesses.filter(({ id }) => id === 'codex' || id === 'pi')
    .map(({ id, name, kind }) => [id, name, kind]), [['codex', 'Codex', 'codex'], ['pi', 'Pi', 'pi']]);
  const gptRoutes = (options) => options.models.filter(({ model }) => gptIds.includes(model));
  assert.deepEqual(gptRoutes(anchored).map(({ model, provider, harnessId, fastHarness }) => [model, provider, harnessId, fastHarness]),
    gptIds.map((id) => [id, 'codex', 'codex', undefined]));
  assert.deepEqual(gptRoutes(moved).map(({ model, provider, harnessId, harness, fastHarness }) => [model, provider, harnessId, harness, fastHarness]),
    gptIds.map((id) => [id, 'codex', 'pi', 'pi', 'codex']));
  assert.deepEqual(moved.profiles.filter(({ id }) => id === 'sol-medium').map(({ provider, harness, fastHarness, fast }) =>
    [provider, harness, fastHarness, fast]), [['codex', 'pi', 'codex', true]]);
  assert.deepEqual(moved.chat, anchored.chat);
  const chatSol = moved.chat.models.find(({ model }) => model === sol);
  assert.deepEqual(chatSol, {
    harnessId: 'hermes', provider: 'codex', model: sol, chatProvider: 'openai-codex', chatModel: sol,
    label: table.models[sol].label, efforts: ['medium'], defaultEffort: 'medium',
  });
  const notManual = structuredClone(fixture);
  notManual.entrances.at(-1).status = 'active';
  assert.ok(!sessionOptionsFrom(notManual).models.some(({ model }) => model === refused));
  notManual.picker.defaultProfile = 'opus-high';
  assert.deepEqual(sessionOptionsFrom(notManual).profiles, [], 'a missing default must not select a manual fallback');
});

test('employee Chat requires a Chat-tagged subscription route, independent of Work availability', () => {
  const table = structuredClone(fixture);
  table.picker.models.find((row) => row.model === sol).surfaces = ['chat'];
  table.picker.models.find((row) => row.model === uncensored).surfaces.push('chat');
  table.picker.harnesses.push(group('claude-api', 'Claude API', 99));
  table.picker.models.push(model('claude-api', opus, ['claude-api-high'], 'high', ['chat']));
  table.employees.providers['claude-api'] = 'claude-api';
  const workUnavailable = (provider) => provider === 'codex' ? { harness: 'pi', available: false, reasonShort: 'unavailable' } : null;
  const { chat, profiles, models } = sessionOptionsFrom(table, workUnavailable);
  assert.ok(!profiles.some(({ model }) => model === sol));
  assert.equal(models.find(({ model }) => model === sol).available, false);
  assert.equal(chat.models.find(({ model }) => model === sol).label, sol);
  assert.ok(!Object.hasOwn(chat.models.find(({ model }) => model === sol), 'available'));
  assert.ok(!chat.models.some(({ provider }) => provider === 'claude-api'));
  // D-33 追記7: the uncensored DeepSeek is offered in Chat on Hermes' uncensored route, marked metered.
  const uncensoredChat = chat.models.find(({ provider }) => provider === 'dsh-refuseless');
  assert.deepEqual([uncensoredChat.chatProvider, uncensoredChat.chatModel, uncensoredChat.metered, uncensoredChat.manual],
    ['laa-monet-uncensored', uncensored, true, true]);
  table.picker.models.find((row) => row.model === sol).surfaces = ['session'];
  assert.ok(!sessionOptionsFrom(table).chat.models.some(({ model }) => model === sol));
});

test('Bridge HTTP lane returns only HQ options in both response variants', async (t) => {
  clearInheritedAdapters(t);
  const root = mkdtempSync(join(tmpdir(), 'laa-lane-'));
  const dir = join(root, 'state'), home = join(root, 'home'), modelsFile = join(home, 'hq/harness/models.json');
  for (const child of ['tmp', 'brain', 'sink']) mkdirSync(join(root, child));
  mkdirSync(dirname(modelsFile), { recursive: true });
  const stage = process.env.D23_STAGE_HQ_MODELS;
  writeFileSync(modelsFile, stage ? readFileSync(stage) : JSON.stringify(fixture));
  const env = { HOME: home, TMPDIR: join(root, 'tmp'), LAA_LANE_ID: 'd23-catalog', LAA_LANE_ROOT: root,
    LAA_BRIDGE_STATE_DIR: dir, LAA_BRIDGE_BRAIN_ROOT: join(root, 'brain'), LAA_BRIDGE_PORT: '0' };
  const saved = Object.fromEntries(Object.keys(env).map((key) => [key, process.env[key]]));
  let bridge;
  t.after(async () => {
    await bridge?.close();
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    rmSync(root, { recursive: true, force: true });
  });
  Object.assign(process.env, env);
  const store = createStore({ dir, idempotencyRetentionMs: IDEMPOTENCY_RETENTION_MS });
  bridge = createBridge({ store, testEndpoints: false, log: null });
  const { port } = await bridge.listen({ port: 0, host: '127.0.0.1' });
  const call = laneClient(`http://127.0.0.1:${port}`, env.LAA_LANE_ID);
  const { code } = issuePairing(store, { name: 'Catalog fixture', scopes: ['sessions:read'], ttlMs: PAIRING_TTL_MS });
  const enrollment = await call('/v1/devices/enroll', { method: 'POST', body: JSON.stringify({ code, name: 'Catalog reader' }) });
  assert.equal(enrollment.status, 201);
  const { data: auth } = await enrollment.json();
  const headers = { authorization: `Bearer ${auth.token}` };
  const read = async (query) => {
    const response = await call(`/v1/session-options${query}`, { headers });
    assert.equal(response.status, 200);
    return (await response.json()).data;
  };
  const options = await read('?catalogOnly=true');
  assert.deepEqual(await read(''), options);
  assert.equal(options.defaultProfile, 'opus-medium');
  assert.equal(options.defaultMode, 'bypass');
  const ids = [opus, sol, go, refused, ...(stage ? ['claude-mythos-5-2', 'gpt-6.2-astra', 'gpt-6.1-terra', 'gemini-4-neon', 'gemini-4-hydrogen'] : [])].sort();
  for (const field of ['models', 'profiles', 'efforts']) assert.deepEqual([...new Set(options[field].map((row) => row.model))].sort(), ids, field);
  for (const field of ['profiles', 'switchProfiles', 'efforts', 'models']) {
    for (const id of [opus, sol]) {
      const rows = options[field].filter(({ model }) => model === id);
      assert.deepEqual(rows.flatMap(({ effort, efforts }) => efforts ?? [effort]), ['medium'], `${field} ${id}`);
    }
  }
  assert.deepEqual(options.harnesses.filter(({ id }) => goGroups.includes(id)).map(({ id, name, kind }) => [id, name, kind]), [
    ['dsh-orchestrator', 'DSH Orchestrator', 'dsh-orchestrator'], ['dsh-worker', 'DSH Worker', 'dsh-worker'],
  ]);
  assert.deepEqual(options.models.filter(({ model }) => model === go).map(({ harnessId, provider, efforts, defaultEffort, manual }) =>
    [harnessId, provider, efforts, defaultEffort, manual]), goGroups.map((id) => [id, 'dsh', ['high', 'max'], 'high', undefined]));
  assert.deepEqual(options.profiles.filter(({ model }) => model === go).map(({ id }) => id), ['deepseek-flash-high', 'deepseek-flash-max']);
  assert.deepEqual(options.efforts.filter(({ model }) => model === go), [{ provider: 'dsh', model: go, efforts: ['high', 'max'], defaultEffort: 'high' }]);
  const manual = options.models.find(({ model }) => model === refused);
  assert.deepEqual([manual.provider, manual.harnessId, manual.surfaces, manual.manual, manual.metered, manual.defaultEffort],
    ['dsh-refuseless', 'dsh-refuseless', ['session'], true, true, 'high']);
  assert.deepEqual(options.chat.harnesses, [{ id: 'hermes', name: 'Hermes', order: 0, kind: 'hermes' }]);
  assert.deepEqual(options.chat.models.map(({ model }) => model).sort(), ids.filter((id) => id !== refused));
  for (const row of options.chat.models) {
    assert.equal(row.harnessId, 'hermes');
    assert.equal(row.chatProvider, hermesProviders[row.provider]);
    assert.equal(row.chatModel, row.model === go ? flash : row.model);
    const session = options.models.find(({ provider, model }) => provider === row.provider && model === row.model);
    assert.deepEqual([row.efforts, row.defaultEffort], [session.efforts, session.defaultEffort]);
  }
  assert.equal(options.chat.models.filter(({ provider }) => provider === 'dsh').length, 1);
  writeFileSync(modelsFile, '{}');
  const refusedReply = await call('/v1/session-options', { headers });
  assert.equal(refusedReply.status, 503);
  assert.equal((await refusedReply.json()).error.code, 'options_unavailable');
});

test('Bridge create enforces published choices while preserving trusted legacy pins, resumes and replays', async (t) => {
  const root = mkdtempSync(join(tmpdir(), 'd23-create-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const modelsFile = join(root, 'models.json');
  const stage = process.env.D23_STAGE_HQ_MODELS;
  const current = stage ? JSON.parse(readFileSync(stage, 'utf8')) : structuredClone(fixture);
  const old = structuredClone(current);
  old.picker.models.find((row) => row.model === opus).profiles.push('opus-high', 'opus-xhigh');
  old.picker.models.find((row) => row.model === sol).profiles.push('sol-high');
  current.dispatch.manual_profiles.push('sol-high');
  writeFileSync(modelsFile, JSON.stringify(old));
  const calls = [];
  const requestedRoutes = {
    'opus-medium': { provider: 'claude', model: opus, effort: 'medium' },
    'opus-high': { provider: 'claude', model: opus, effort: 'high' },
    'opus-xhigh': { provider: 'claude', model: opus, effort: 'xhigh' },
    'sol-high': { provider: 'codex', model: sol, effort: 'high' },
  };
  const pinned = { id: 'project-a', defaultProfile: 'opus-xhigh' };
  const unpinned = { id: 'project-b' };
  const choices = sessionOptionsReader({ file: modelsFile });
  const sessions = createSessionService({
    choices, sessionStore: createSessionStore({ file: join(root, 'sessions.json') }), homeCwd: root,
    findProject: (id) => [pinned, unpinned].find((project) => project.id === id),
    adapter: {
      create: async ({ requestId, profile }) => {
        calls.push(profile);
        return { sessionId: requestId, requested: { profile, ...requestedRoutes[profile] } };
      },
      stop: async () => ({ daemonStatus: 'stopped' }),
    },
  });
  const create = (body) => sessions.createSession({ deviceId: 'fixture-device', body });
  const resume = (id, body) => sessions.resumeSession({ id, body, key: `resume-${id}`, deviceId: 'fixture-device' });
  const createBody = (requestId, projectId, extras = {}) => ({ requestId, prompt: 'fixture only', projectId, mode: 'bypass', fast: false, ...extras });
  const legacy = [];
  for (const profile of ['opus-high', 'opus-xhigh', 'sol-high']) {
    const body = createBody(`legacy-${profile}`, unpinned.id, { profile });
    const reply = await create(body);
    assert.equal(reply.created, true);
    const id = reply.session.id;
    const stopped = await sessions.stopSession(id);
    assert.equal(stopped.session.phase, 'stopped');
    legacy.push({ profile, body, id });
  }
  writeFileSync(modelsFile, JSON.stringify(current));
  const catalog = choices();
  assert.equal(catalog.defaultProfile, 'opus-medium');
  const defaultWire = catalog.profiles.find(({ id }) => id === catalog.defaultProfile);
  assert.deepEqual([defaultWire.id, defaultWire.provider, defaultWire.model, defaultWire.effort], ['opus-medium', 'claude', opus, 'medium']);
  assert.ok(!catalog.profiles.some(({ id }) => ['opus-high', 'opus-xhigh', 'sol-high'].includes(id)));

  const implicit = createBody('unpinned', unpinned.id);
  const automatic = await create(implicit);
  const app = await create(createBody('current-app', unpinned.id, { profile: defaultWire.id }));
  const savedBody = createBody('saved-project', pinned.id);
  const project = await create(savedBody);
  for (const [reply, profile] of [[automatic, 'opus-medium'], [app, 'opus-medium'], [project, 'opus-xhigh']]) {
    assert.equal(reply.created, true);
    assert.equal(reply.session.profile, profile);
    assert.deepEqual(reply.session.requested, { profile, ...requestedRoutes[profile] });
  }
  assert.equal(calls.length, 6);
  for (const [index, profile] of ['opus-high', 'opus-xhigh', 'sol-high', 'unlisted-fixture'].entries()) {
    await assert.rejects(create(createBody(`unlisted-${index}`, pinned.id, { profile, resumedFrom: legacy[0].id })),
      { status: 400, code: 'model_choice_invalid' });
  }
  const replayHidden = await create(legacy[0].body);
  assert.equal(replayHidden.created, false);
  assert.equal(replayHidden.session.id, legacy[0].id);
  await assert.rejects(create({ ...legacy[0].body, prompt: 'changed fixture request' }), { status: 409 });
  assert.equal(calls.length, 6);
  await assert.rejects(resume(legacy[0].id, { message: 'fixture continuation', profile: 'sol-high' }), { status: 400, code: 'model_change_rejected' });
  const resumed = await resume(legacy[0].id, { message: 'fixture continuation' });
  assert.equal(resumed.created, true);
  assert.equal(resumed.session.profile, legacy[0].profile);
  assert.equal(resumed.session.resumedFrom, legacy[0].id);
  for (const { id } of legacy.slice(1)) {
    await assert.rejects(resume(id, { message: 'fixture continuation' }), { status: 400, code: 'model_choice_invalid' });
  }
  assert.deepEqual(calls, ['opus-high', 'opus-xhigh', 'sol-high', 'opus-medium', 'opus-medium', 'opus-xhigh', 'opus-high']);
  const { retainedProfile: retained } = choices;
  assert.equal(retained('opus-high'), null);
  assert.equal(retained('opus-high', { sameProfileResume: true }).model, opus);
  assert.equal(retained('opus-xhigh', { sameProfileResume: true }), null);
  assert.equal(retained('sol-high', { sameProfileResume: true }), null);
  assert.equal(retained('opus-xhigh', { savedPin: true }).model, opus);
  const movedDefault = structuredClone(current);
  movedDefault.picker.defaultProfile = 'sol-medium';
  writeFileSync(modelsFile, JSON.stringify(movedDefault));
  unpinned.defaultProfile = 'sol-medium';
  const retry = await create(implicit);
  assert.equal(retry.created, false);
  assert.equal(retry.session.id, automatic.session.id);
  assert.equal(retry.session.profile, 'opus-medium');
  assert.equal(pinned.defaultProfile, 'opus-xhigh');
  delete movedDefault.profiles['opus-xhigh'];
  writeFileSync(modelsFile, JSON.stringify(movedDefault));
  const replayPin = await create(savedBody);
  assert.equal(replayPin.created, false);
  assert.equal(replayPin.session.id, project.session.id);
  await assert.rejects(create(createBody('missing-project-profile', pinned.id)), { status: 409, code: 'project_default_unavailable' });
  assert.equal(calls.length, 7);
});
