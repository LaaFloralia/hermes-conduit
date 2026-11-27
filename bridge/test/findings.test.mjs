import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { createFindingStore, findingNeedsOwner } from '../src/findings/store.mjs';
import { createFindingService } from '../src/findings/service.mjs';
import { createRefRegistry } from '../src/refs/registry.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { startBridge } from './helpers.mjs';

const DAY = 86_400_000;
const start = Date.parse('2026-11-27T00:00:00Z');
const cli = fileURLToPath(new URL('../bin/laa-bridge', import.meta.url));
const input = { requestId: 'finding-test', title: '検証手順を整理', found: '同じ手順が重複', evidence: 'テストの読み戻し', plan: '共通テストにまとめる', effort: 'small' };
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAIAAAA8r+mnAAAAFklEQVR4nGP4z8DAAMb/wTQcMVBPAgBOah/h5EgP7QAAAABJRU5ErkJggg==', 'base64');
const clock = () => ({ at: start, now() { return this.at; } });
const disk = (dir) => JSON.parse(readFileSync(join(dir, 'findings.json'), 'utf8')).records;
const registryAt = (dir, now) => createRefRegistry({ file: join(dir, 'refs.json'), now });

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'laa-lane-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const part of ['home', 'tmp', 'brain']) mkdirSync(join(root, part), { mode: 0o700 });
  const dir = join(root, 'state');
  const time = clock(), now = time.now.bind(time);
  const store = createFindingStore({ dir, now });
  const service = createFindingService({ store });
  return { root, dir, store, service, time, now };
}

function cliFor(root, dir) {
  const env = { HOME: join(root, 'home'), TMPDIR: join(root, 'tmp'), PATH: `${dirname(process.execPath)}:/usr/bin:/bin`,
    NODE_TEST_CONTEXT: process.env.NODE_TEST_CONTEXT, LAA_LANE_ID: 'findings-unit', LAA_LANE_ROOT: root, LAA_BRIDGE_STATE_DIR: dir,
    LAA_BRIDGE_PORT: '0', LAA_BRIDGE_BRAIN_ROOT: join(root, 'brain'), PASEO_AGENT_ID: 'test-agent' };
  return (args, expected = 0, { json = true, overrides } = {}) => {
    const child = spawnSync(cli, ['finding', ...args, ...(json ? ['--json'] : [])], { env: { ...env, ...overrides }, encoding: 'utf8', timeout: 30_000 });
    assert.ifError(child.error);
    assert.equal(child.status, expected, child.stderr);
    return json ? JSON.parse(child.stdout) : child.stdout;
  };
}
const addArgs = (row = input) => ['add', ...Object.entries({ ...row, 'request-id': row.requestId }).filter(([key]) => key !== 'requestId')
  .flatMap(([key, value]) => [`--${key}`, value])];

function seedImage(dir, id) {
  const image = { id: 'img_000000000001', width: 8, height: 4 };
  const path = join(dir, 'findings.json');
  const doc = JSON.parse(readFileSync(path, 'utf8'));
  doc.records.find((row) => row.id === id).images = [image];
  writeFileSync(path, JSON.stringify(doc));
  const folder = join(dir, 'finding-images', id, image.id);
  mkdirSync(folder, { recursive: true, mode: 0o700 });
  for (const size of ['full', 'thumb']) writeFileSync(join(folder, `${image.id}.${size}.png`), png, { mode: 0o600 });
  return { ...image, folder };
}

test('owner-only rule counts remaining meaningful characters and checks both physical-action fields', (t) => {
  const { store, dir } = fixture(t);
  for (const plan of ['課金。', '支払いをする', '購入・契約・解約', '売買、注文', '削除・消去・公開・投稿', '署名、振込、送信', 'Please pay.', 'DELETE the file!', 'pay 1234567', 'Publish 🗂️', 'Sign. Post. Send.']) {
    assert.equal(findingNeedsOwner('test', plan), true, plan);
    assert.throws(() => store.add({ ...input, plan }), { code: 'finding_needs_owner', message: /社長担当のLinear Task/ });
  }
  for (const text of ['本人のログイン', '社長が操作', '社長が確認', '社長がログイン']) {
    assert(findingNeedsOwner(text, 'Review the flow and document it.'));
    assert(findingNeedsOwner('test', `Review the flow and document it. ${text}`));
  }
  for (const plan of ['調査', 'posture', 'pay 12345678', '公開条件を調査し、検証結果を文書化する', 'Draft a migration and review the risks before we delete.']) {
    assert.equal(findingNeedsOwner('test', plan), false, plan);
  }
  assert(!existsSync(dir));
});

test('requestId updates only open content and validates one-line text and Unicode limits; corrupt state fails closed', (t) => {
  const { store, time, dir } = fixture(t);
  const first = store.add({ ...input, source: { sessionId: 'agent-a', name: 'Session A' } });
  time.at += DAY;
  const update = { ...input, title: '🚀'.repeat(40), found: '変更\n次の行', evidence: '読戻し', plan: '共通化', effort: 'medium' };
  const updated = store.add({ ...update, source: { sessionId: 'agent-b' } });
  assert.match(first.id, /^fnd_[0-9a-f]{16}$/);
  for (const key of ['id', 'createdAt']) assert.equal(updated[key], first[key]);
  for (const key of ['title', 'found', 'evidence', 'plan', 'effort']) assert.equal(updated[key], update[key]);
  assert.deepEqual(updated.source, first.source);
  assert.notEqual(updated.updatedAt, first.updatedAt);
  assert.deepEqual(updated.images, []);
  const delegated = store.delegate(first.id);
  assert.deepEqual(store.add(input), delegated);
  assert.deepEqual(disk(dir), [delegated]);
  assert.equal(statSync(join(dir, 'findings.json')).mode & 0o777, 0o600);
  for (const patch of [{ title: '🚀'.repeat(41) }, { title: '二\n行' }, { found: 'x'.repeat(601) }, { evidence: 'x'.repeat(1201) },
    { plan: 'x'.repeat(1201) }, { requestId: 'x'.repeat(201) }, { effort: 'huge' }]) {
    assert.throws(() => store.add({ ...input, ...patch }), { code: 'finding_invalid' });
  }
  assert.throws(() => store.done(first.id, '二\n行'), { code: 'finding_invalid' });
  assert.throws(() => store.done(first.id, 'x'.repeat(201)), { code: 'finding_invalid' });
  const path = join(dir, 'findings.json');
  writeFileSync(path, '{ broken');
  assert.throws(() => store.add(input), { code: 'findings_store_unavailable' });
  assert.equal(readFileSync(path, 'utf8'), '{ broken');
});

test('transitions and retention: pickup once, done/dismissed purge at seven days', (t) => {
  const { store, service, time, dir } = fixture(t);
  const open = store.add(input);
  const done = store.add({ ...input, requestId: 'done' });
  const dismissed = store.add({ ...input, requestId: 'dismissed' });
  const doneImg = seedImage(dir, done.id);
  const dismissedImg = seedImage(dir, dismissed.id);
  assert.throws(() => store.pickup(open.id, 'test-plan'), { code: 'finding_state' });
  assert.throws(() => store.done(open.id, '未完了'), { code: 'finding_state' });
  store.delegate(done.id);
  const pickup = store.pickup(done.id, 'test-plan');
  time.at += DAY;
  assert.deepEqual(store.pickup(done.id, 'test-plan'), pickup);
  assert.throws(() => store.pickup(done.id, 'other-plan'), { code: 'finding_state' });
  store.done(done.id, '検証済み');
  store.dismiss(dismissed.id);
  assert.throws(() => store.dismiss(done.id), { code: 'finding_state' });
  assert.throws(() => store.delegate(dismissed.id), { code: 'finding_state' });
  assert.deepEqual(service.stats(), { open: 1, delegated: 0, done: 1, dismissed: 1, staleDismissed: 0 });
  assert.deepEqual(service.list().items.map((r) => r.id).sort(), [open.id, done.id].sort());
  time.at += 7 * DAY - 1;
  assert.equal(service.list({ status: 'done' }).items[0].result, '検証済み');
  assert(existsSync(doneImg.folder) && existsSync(dismissedImg.folder));
  time.at++;
  assert.deepEqual(service.list({ status: 'done' }).items, []);
  assert.deepEqual(disk(dir).map((r) => r.id), [open.id]);
  assert(!existsSync(doneImg.folder) && !existsSync(dismissedImg.folder));
});

test('retention auto-dismisses only open findings unchanged for 30 days, releases F, then purges images and count', (t) => {
  const { store, time, dir, now } = fixture(t);
  const refs = registryAt(dir, now);
  const service = createFindingService({ store, refFor: refs.refFor, observe: refs.observeComplete });
  const open = store.add(input);
  const refreshed = store.add({ ...input, requestId: 'refreshed' });
  const delegated = store.add({ ...input, requestId: 'delegated' });
  store.delegate(delegated.id);
  service.reconcile();
  assert.match(refs.refFor('finding', open.id), /^F\d+$/);
  time.at += 29 * DAY;
  assert.equal(store.add(input).updatedAt, open.updatedAt);
  store.add({ ...input, requestId: 'refreshed', title: '検証手順を更新' });
  const image = seedImage(dir, open.id);
  time.at = start + 30 * DAY - 1;
  assert.equal(service.get(open.id).status, 'open');
  time.at++;
  store.sweep();
  assert.deepEqual(service.list().items.map(({ id }) => id).sort(), [refreshed.id, delegated.id].sort());
  const dismissedAt = new Date(now()).toISOString();
  assert.deepEqual(service.get(open.id, { local: true }), { ...open, images: [{ id: image.id, width: image.width, height: image.height }],
    ref: null, sourceRef: null, status: 'dismissed', dismissedBy: 'stale', result: '30日動きがないため取り下げ',
    dismissedAt, updatedAt: dismissedAt });
  assert.equal(refs.refFor('finding', open.id), null);
  assert.deepEqual(service.stats(), { open: 1, delegated: 1, done: 0, dismissed: 1, staleDismissed: 1 });
  time.at += 7 * DAY - 1;
  assert(existsSync(image.folder));
  assert.equal(service.stats().staleDismissed, 1);
  time.at++;
  assert.equal(service.stats().staleDismissed, 0);
  assert(!disk(dir).some(({ id }) => id === open.id));
  assert(!existsSync(image.folder));
});

test('CLI writes local state, infers source name, reads server F numbers, and uses contract output and exit codes', (t) => {
  const { root, dir, now } = fixture(t);
  const run = cliFor(root, dir);
  const sessions = createSessionStore({ file: join(dir, 'sessions.json') });
  sessions.create({ record: { id: 'ses_fixture', name: 'Test Session', delegate: { sessionId: 'test-agent' } } });
  assert.match(run(['help'], 0, { json: false }), /気づき/);
  assert.equal(run(['add', '--title'], 2).error.code, 'usage_error');
  assert.equal(run(addArgs({ ...input, plan: '支払' }), 5).error.code, 'finding_needs_owner');
  const { finding } = run(addArgs());
  assert.equal(finding.requestId, input.requestId);
  assert.equal(finding.ref, null);
  assert.deepEqual(finding.source, { sessionId: 'ses_fixture', name: 'Test Session' });
  assert(!existsSync(join(dir, 'refs.json')));
  const refs = registryAt(dir, now);
  const { ref } = refs.assign({ kind: 'finding', key: finding.id });
  assert.equal(ref, 'F1');
  const refsBefore = readFileSync(join(dir, 'refs.json'), 'utf8');
  assert.equal(run(['show', 'ｆ-０１']).finding.ref, ref);
  const unknown = run([...addArgs({ ...input, requestId: 'named' }), '--agent', 'other-agent', '--name', 'Source']);
  assert.deepEqual(unknown.finding.source, { sessionId: 'other-agent', name: 'Source' });
  assert.match(run(addArgs(), 0, { json: false }), new RegExp(`^気づきへ登録しました（F1 · ${finding.id}）。作業は止めずに続けてください。完了報告の提案にはF1とだけ書きます。`));
  assert.equal(run(['delegate', ref]).finding.status, 'delegated');
  assert.equal(run(['dismiss', ref], 4).error.code, 'finding_state');
  const plan = run(['pickup', ref, '--plan', 'finding-fixture']).finding.pickup;
  assert.deepEqual(run(['pickup', ref, '--plan', plan.plan]).finding.pickup, plan);
  assert.equal(run(['list', '--status', 'delegated']).items[0].id, finding.id);
  assert.equal(run(['done', ref, '--result', '確認済み']).finding.result, '確認済み');
  assert.equal(run(['dismiss', unknown.finding.id]).finding.status, 'dismissed');
  assert.equal(run(['list']).items.length, 1);
  assert.deepEqual(run(['stats']), { ok: true, open: 0, delegated: 0, done: 1, dismissed: 1, staleDismissed: 0 });
  assert.equal(run(['show', 'F99999'], 3).error.code, 'finding_not_found');
  assert.equal(readFileSync(join(dir, 'refs.json'), 'utf8'), refsBefore);
  assert.match(run(['list'], 1, { json: false, overrides: { LAA_BRIDGE_STATE_DIR: join(root, '..', 'must-not-open') } }), /^$/);
});

test('HTTP auth, scope, state-idempotent POST, F assignment/release, and private image responses', async (t) => {
  const time = clock(), now = time.now.bind(time);
  const notices = [];
  const h = await startBridge({ now, decisions: { notify: (...args) => notices.push(args) }, sessions: { notify: (...args) => notices.push(args) } });
  t.after(() => h.close());
  const store = createFindingStore({ dir: h.stateDir, now });
  const a = store.add({ ...input, source: { sessionId: 'ses_fixture', name: 'Test Session' } });
  time.at += 1000;
  const b = store.add({ ...input, requestId: 'newest' });
  const refs = registryAt(h.stateDir, now);
  refs.assign({ kind: 'session', key: 'ses_fixture' });
  const img = seedImage(h.stateDir, a.id);
  const route = '/v1/findings';
  const detail = `${route}/${a.id}`, media = `${detail}/images/${img.id}`;
  const read = await h.token(['sessions:read']), write = await h.token(['sessions:write']), other = await h.token(['brain:read']);
  const get = (path, token = read, headers) => h.request(path, { token, headers });
  const post = (path, token) => h.request(path, { method: 'POST', token });
  for (const path of [route, detail, media]) {
    assert.equal((await h.request(path)).status, 401);
    assert.equal((await get(path, other)).status, 403);
  }
  const { data } = (await get(route)).body;
  assert.deepEqual(data.counts, { open: 2, delegated: 0, done: 0 });
  assert.deepEqual(data.items.map((r) => r.id), [b.id, a.id]);
  assert.deepEqual(data.items.map((r) => r.ref), ['F2', 'F1']);
  assert.equal(data.items[1].sourceRef, 'S1');
  assert(!Object.hasOwn((await get(detail)).body.data, 'requestId'));
  assert.equal((await get('/v1/refs/F1')).body.data.holder.key, a.id);
  for (const path of [media, `${media}?size=thumb`]) {
    const full = await get(path);
    assert.equal(full.status, 200);
    const { data: base64, etag, contentType, width, height } = full.body.data;
    assert.deepEqual(Buffer.from(base64, 'base64'), png);
    assert.deepEqual([contentType, width, height], ['image/png', 8, 4]);
    assert.equal(full.headers.get('etag'), etag);
    const cached = await get(path, read, { 'if-none-match': `"other", W/${etag}` });
    assert.equal(cached.status, 304);
    assert.equal(cached.headers.get('etag'), etag);
    assert.equal(cached.body, null);
  }
  assert.equal((await get(`${detail}/images/img_000000000002`)).status, 404);
  assert.equal((await post(`${detail}/delegate`)).status, 401);
  assert.equal((await post(`${detail}/delegate`, read)).status, 403);
  const delegated = await post(`${detail}/delegate`, write);
  assert.equal(delegated.status, 200);
  assert.equal(delegated.body.data.finding.status, 'delegated');
  time.at += 1000;
  assert.deepEqual((await post(`${detail}/delegate`, write)).body.data, delegated.body.data);
  assert.equal((await post(`${detail}/dismiss`, write)).body.error.code, 'finding_state');
  store.pickup(a.id, 'finding-fixture');
  assert.deepEqual((await get(detail)).body.data.pickup, { plan: 'finding-fixture', at: new Date(now()).toISOString() });
  const dismiss = `${route}/${b.id}/dismiss`;
  const dismissed = await post(dismiss, write);
  assert.equal(dismissed.body.data.finding.status, 'dismissed');
  assert.deepEqual((await post(dismiss, write)).body.data, dismissed.body.data);
  assert.deepEqual((await get(`${route}/${b.id}`)).body.data, dismissed.body.data.finding);
  assert(!(await get(route)).body.data.items.some((row) => row.id === b.id));
  assert.equal(refs.refFor('finding', b.id), null);
  store.done(a.id, '検証済み');
  assert.equal((await get(route)).body.data.counts.done, 1);
  assert.equal(refs.refFor('finding', a.id), 'F1');
  time.at += 7 * DAY;
  assert.equal((await get(media)).status, 410);
  assert.deepEqual((await get(route)).body.data, { items: [], counts: { open: 0, delegated: 0, done: 0 } });
  assert.equal(refs.refFor('finding', a.id), null);
  assert.deepEqual(notices, []);
});

test('CLI refuses invalid, excess and out-of-lane images before saving', (t) => {
  const { root, dir } = fixture(t);
  const run = cliFor(root, dir);
  const bad = join(root, 'bad.png');
  writeFileSync(bad, 'not an image');
  for (const path of ['relative.png', bad, join(root, '..', 'outside.png')]) {
    assert.match(run([...addArgs(), '--image', path], 5).error.code, /image_invalid$/);
  }
  assert.match(run([...addArgs(), ...Array.from({ length: 7 }, () => ['--image', bad]).flat()], 5).error.code, /image_invalid$/);
  assert(!existsSync(join(dir, 'findings.json')));
});

test('CLI copies images privately, safely replaces sets, and preserves the prior set on failed update', { skip: process.platform !== 'darwin' }, (t) => {
  const { root, dir, store, time } = fixture(t);
  const run = cliFor(root, dir);
  const source = join(root, 'source.png');
  writeFileSync(source, png);
  const { finding } = run([...addArgs(), '--image', source]);
  const first = finding.images[0];
  assert.deepEqual([first.width, first.height, first.option], [8, 4, undefined]);
  const file = join(dir, 'finding-images', finding.id, first.id, `${first.id}.full.png`);
  assert.equal(statSync(file).mode & 0o777, 0o600);
  assert(!readFileSync(join(dir, 'findings.json'), 'utf8').includes(source));
  rmSync(source);
  assert.equal(store.image(finding.id, first.id, 'thumb').width, 8);
  assert.equal(run([...addArgs(), '--image', source], 5).ok, false);
  assert.deepEqual(disk(dir)[0].images, [first]);
  writeFileSync(source, png);
  const next = run([...addArgs(), '--image', source, '--image', source]).finding;
  assert.equal(next.id, finding.id);
  assert.equal(next.images.length, 2);
  assert.throws(() => store.image(finding.id, first.id), { status: 404 });
  assert.equal(store.image(next.id, next.images[0].id).contentType, 'image/png');
  time.at = Date.now() + 2 * 3600_000;
  store.sweep();
  assert(!existsSync(file));
  assert.deepEqual(run(addArgs()).finding.images, next.images);
});
