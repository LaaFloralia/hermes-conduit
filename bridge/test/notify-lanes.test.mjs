// C-2 notification lanes: finished off by default, a named Monet report kind with
// a permanent dedupe ledger, decisions and errors unchanged, explicit choices kept.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createOwnerNotifier } from '../src/notify/index.mjs';
import { createNotificationPreferences, DEFAULT_KINDS, notificationLevel } from '../src/notify/preferences.mjs';

const dirFor = (t) => { const dir = mkdtempSync(join(tmpdir(), 'laa-lanes-')); t.after(() => rmSync(dir, { recursive: true, force: true })); return dir; };
const decode = (e) => JSON.parse(Buffer.from(e.session_id.split('#')[1], 'base64url').toString());
const report = (requestId = 'req_1', projectId = 'prj_1') => ({ kind: 'monet.report', title: '要件が完了しました', body: '確認済みです。',
  deepLink: `laa://work/projects/${projectId}`, dedupeKey: `monet.report:${projectId}:${requestId}`, meta: { projectId, requestId } });
const finished = (dedupeKey = 'fin') => ({ kind: 'session.finished', title: '終了', body: '本文', deepLink: 'laa://work/sessions/ses_1', dedupeKey });

test('fresh defaults: finished off, report named alert, decision/question/approval/error alert', (t) => {
  const prefs = createNotificationPreferences({ file: join(dirFor(t), 'p.json') });
  assert.equal(prefs.get().kinds.finished, 'off');
  assert.equal(prefs.get().kinds.report, 'alert');
  for (const kind of ['decision.new', 'decision.failed', 'session.question', 'session.approval', 'session.error', 'monet.report'])
    assert.equal(notificationLevel(kind, prefs), 'alert', kind);
  assert.equal(notificationLevel('session.finished', prefs), 'off');
  assert.equal(notificationLevel('unknown.kind', prefs), 'alert');
});

test('updates store only explicit kinds; an absent kind follows the default', (t) => {
  const file = join(dirFor(t), 'p.json');
  const prefs = createNotificationPreferences({ file, now: () => 1000 });
  prefs.update({ kinds: { task: 'quiet' } });
  assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')).kinds, { task: 'quiet' });
  assert.deepEqual(prefs.get().kinds, { ...DEFAULT_KINDS, task: 'quiet' });
});

test('the owner can still choose alert, quiet or off for finished and report; decisions stay unmutable', (t) => {
  const prefs = createNotificationPreferences({ file: join(dirFor(t), 'p.json') });
  for (const kind of ['finished', 'report']) for (const level of ['alert', 'quiet', 'off']) {
    prefs.update({ kinds: { [kind]: level } });
    assert.equal(prefs.get().kinds[kind], level, `${kind}=${level}`);
  }
  for (const kind of ['decision', 'question', 'approval']) assert.throws(() => prefs.update({ kinds: { [kind]: 'off' } }));
});

test('legacy finished=quiet migrates once, except for a recorded owner choice', (t) => {
  const dir = dirFor(t);
  // Pre-change files carry every default materialized by the first update, so quiet has unknown provenance.
  const legacyKinds = { decision: 'alert', question: 'alert', approval: 'alert', error: 'alert', finished: 'quiet', task: 'alert', calendar: 'alert' };
  for (const [name, doc] of [['s1.json', { schema: 1, kinds: legacyKinds, updatedAt: '2026-11-20T00:00:00.000Z' }],
    ['less.json', { kinds: legacyKinds, updatedAt: '2026-11-20T00:00:00.000Z' }]]) {
    const file = join(dir, name), original = JSON.stringify(doc);
    writeFileSync(file, original);
    const prefs = createNotificationPreferences({ file, now: () => 2000 });
    assert.equal(prefs.get().kinds.finished, 'off');
    assert.equal(prefs.get().kinds.report, 'alert');
    const migrated = readFileSync(file, 'utf8');
    assert.equal(JSON.parse(migrated).finishedDefaultMigratedAt, new Date(2000).toISOString());
    prefs.get();
    assert.equal(readFileSync(file, 'utf8'), migrated, 'migration happens once');
    writeFileSync(file, JSON.stringify({ ...doc, updatedBy: 'owner' }));
    assert.equal(prefs.get().kinds.finished, 'quiet');
    prefs.update({ kinds: { task: 'off' } });
    assert.equal(JSON.parse(readFileSync(file, 'utf8')).kinds.finished, 'quiet');
  }
});

test('fresh install: finished is muted, a report is delivered once as alert, decisions untouched', async (t) => {
  const dir = dirFor(t), sent = [];
  const notify = createOwnerNotifier({ file: join(dir, 'n.json'), deliver: async (e) => { sent.push(e); return { delivered: true }; } });
  assert.equal((await notify(finished())).reason, 'muted');
  assert.equal((await notify({ ...finished('err'), kind: 'session.error' })).delivered, true);
  assert.equal((await notify(report())).delivered, true);
  assert.deepEqual(sent.map((e) => decode(e).k), ['session.error', 'monet.report']);
  assert.equal(decode(sent[1]).lv, undefined);
});

test('report dedupe survives restarts and the 7-day / 2000-row window of other kinds', async (t) => {
  const dir = dirFor(t), file = join(dir, 'n.json'), sent = [];
  let clock = Date.parse('2026-11-25T00:00:00Z');
  const make = () => createOwnerNotifier({ file, now: () => clock, deliver: async (e) => { sent.push(e); return { delivered: true }; } });
  assert.equal((await make()(report())).delivered, true);
  clock += 8 * 86400_000;
  assert.equal((await make()({ ...finished('err'), kind: 'session.error' })).delivered, true); // prunes the 7-day window
  const state = JSON.parse(readFileSync(file, 'utf8'));
  assert.equal(Object.keys(state.delivered).length, 1, 'the general window dropped the report');
  assert.equal(Object.keys(state.reports).length, 1, 'the report ledger kept it');
  assert.equal((await make()(report())).reason, 'duplicate');
  assert.equal((await make()(report('req_2'))).delivered, true);
  assert.deepEqual(sent.map((e) => decode(e).k), ['monet.report', 'session.error', 'monet.report']);
});

test('a replay cannot re-queue a report with an expired ambiguous delivery', async (t) => {
  const file = join(dirFor(t), 'n.json');
  let now = 1000, attempts = 0;
  const notify = createOwnerNotifier({ file, now: () => now, deliver: async () => { attempts++; return { delivered: false }; } });
  assert.equal((await notify(report())).queued, true);
  assert.equal((await notify(report())).reason, 'duplicate');
  now += 8 * 86400_000;
  await notify.flush();
  assert.equal((await notify(report())).reason, 'duplicate');
  assert.equal(attempts, 1);
});

test('a report whose dedupe key is not derived from its request is refused', async (t) => {
  const notify = createOwnerNotifier({ file: join(dirFor(t), 'n.json'), deliver: async () => assert.fail('sent') });
  for (const bad of [{ dedupeKey: 'monet.report:prj_1:other' }, { dedupeKey: 'free-form' }, { meta: {} }, { meta: { projectId: 'prj_1' } }])
    assert.equal((await notify({ ...report(), ...bad })).reason, 'invalid_notification');
});

test('a failed report delivery is retried, not recorded as delivered', async (t) => {
  const dir = dirFor(t), file = join(dir, 'n.json');
  let ok = false, attempts = 0;
  const notify = createOwnerNotifier({ file, deliver: async () => { attempts++; return { delivered: ok }; } });
  assert.equal((await notify(report())).queued, true);
  assert.equal(JSON.parse(readFileSync(file, 'utf8')).reports, undefined);
  ok = true; await notify.flush();
  assert.equal(attempts, 2);
  assert.equal((await notify(report())).reason, 'duplicate');
});

test('an explicit report=off mutes reports without touching the ledger', async (t) => {
  const dir = dirFor(t);
  const preferences = createNotificationPreferences({ file: join(dir, 'p.json') });
  preferences.update({ kinds: { report: 'off' } });
  const notify = createOwnerNotifier({ file: join(dir, 'n.json'), preferences, deliver: async () => assert.fail('sent') });
  assert.equal((await notify(report())).reason, 'muted');
});
