import { test } from 'node:test';
import assert from 'node:assert/strict';
import { changeRequirement, parseAcceptance, projectRequirements } from '../src/routes/project-requirements.mjs';

const iso = '2026-11-28T09:00:00.000Z';
const FLOW = 'flw_0123456789ab';
const acceptance = [{ id: 'a1', text: '画面に件数が出る', check: 'アプリで一覧を開く' }, { id: 'a2', text: 'テストが通る' }];
const project = () => ({ id: 'prj_aaaaaaaaaaaa', requirements: [] });
const change = (record, action, body, author, id) => changeRequirement(record, { action, id, body, iso, author, belongs: () => true });
const thrown = (fn) => { try { fn(); } catch (error) { return error; } return null; };

test('the flow authors write acceptance, design and flowId; old records stay valid', () => {
  const record = project();
  change(record, 'add', { title: '件数を出す', source: 'owner' }, 'owner');
  const [plain] = projectRequirements(record);
  assert.equal(plain.acceptance, undefined);
  change(record, 'update', { acceptance, flowId: FLOW, design: { flowId: FLOW, summary: '一覧に件数', advisedBy: 'mythos-high', staff: ['cto', 'cos'] } }, 'bridge', plain.id);
  const [designed] = projectRequirements(record);
  assert.deepEqual(designed.acceptance.map((item) => [item.id, item.status, item.check]), [['a1', 'open', 'アプリで一覧を開く'], ['a2', 'open', null]]);
  assert.equal(designed.flowId, FLOW);
  assert.deepEqual(designed.design.staff, ['cto', 'cos']);
  assert.equal(designed.title, '件数を出す');
});

test('an implementation session and the app cannot rewrite the acceptance criteria', () => {
  const record = project();
  change(record, 'add', { title: '件数を出す', source: 'owner', acceptance }, 'monet');
  const { id } = projectRequirements(record)[0];
  for (const author of ['agent', 'owner']) {
    const error = thrown(() => change(record, 'update', { acceptance: [] }, author, id));
    assert.equal(error?.code, 'requirement_design_forbidden');
    assert.equal(error.status, 403);
  }
  assert.equal(thrown(() => change(record, 'add', { title: '別件', source: 'ai', flowId: FLOW }, 'agent'))?.code, 'requirement_design_forbidden');
  assert.equal(projectRequirements(record)[0].acceptance.length, 2);
});

test('completed is refused while an acceptance item is not passed', () => {
  const record = project();
  change(record, 'add', { title: '件数を出す', source: 'owner', acceptance }, 'bridge');
  const { id } = projectRequirements(record)[0];
  const done = { status: 'completed', verifiedBy: 'monet', note: '実物を確認' };
  for (const author of ['agent', 'monet', 'bridge']) {
    const error = thrown(() => change(record, 'update', done, author, id));
    assert.equal(error?.code, 'acceptance_open');
    assert.deepEqual(error.details.open, ['a1', 'a2']);
  }
  assert.equal(projectRequirements(record)[0].status, 'not_started');
  // One change may pass the items and complete the requirement.
  const passed = acceptance.map((item) => ({ ...item, status: 'passed', note: '確認済み', checkedAt: iso }));
  const half = [passed[0], { ...acceptance[1], status: 'failed' }];
  assert.equal(thrown(() => change(record, 'update', { ...done, acceptance: half }, 'monet', id))?.code, 'acceptance_open');
  assert.equal(change(record, 'update', { ...done, acceptance: passed }, 'monet', id), true);
  const [row] = projectRequirements(record);
  assert.equal(row.status, 'completed');
  assert.equal(row.verifiedBy, 'monet');
  assert.equal(row.verifiedAt, iso);
  // The owner closes by hand in the app, whatever the items say.
  const other = project();
  change(other, 'add', { title: '手で閉じる', source: 'owner', acceptance }, 'bridge');
  assert.equal(change(other, 'update', { status: 'completed' }, 'owner', projectRequirements(other)[0].id), true);
});

test('acceptance limits', () => {
  assert.throws(() => parseAcceptance(Array.from({ length: 13 }, (_, i) => ({ id: `a${i}`, text: 'x' }))), /at most 12/);
  assert.throws(() => parseAcceptance([{ id: 'a1', text: 'x' }, { id: 'a1', text: 'y' }]), /distinct/);
  assert.throws(() => parseAcceptance([{ id: 'a1', text: 'あ'.repeat(101) }]), /300 bytes/);
  assert.throws(() => parseAcceptance([{ id: 'a1', text: 'x', check: 'c'.repeat(601) }]), /600 bytes/);
  assert.throws(() => parseAcceptance([{ id: 'a1', text: 'x', status: 'done' }]), /open, passed or failed/);
  assert.throws(() => parseAcceptance([{ id: 'a1', text: 'x', note: '二行\nです' }]), /single line/);
  assert.deepEqual(parseAcceptance(null), []);
});

test('an agent cannot sidestep acceptance by withdrawing or by completing a flow requirement that has no items', () => {
  const record = project();
  change(record, 'add', { title: '件数を出す', source: 'owner', acceptance, flowId: FLOW }, 'bridge');
  const { id } = projectRequirements(record)[0];
  assert.equal(thrown(() => change(record, 'withdraw', {}, 'agent', id))?.code, 'requirement_withdraw_forbidden');
  assert.equal(projectRequirements(record).length, 1);
  // A flow requirement whose acceptance list is empty cannot be completed by anyone but the owner.
  const bare = project();
  change(bare, 'add', { title: '設計前', source: 'owner', flowId: FLOW }, 'bridge');
  const bareId = projectRequirements(bare)[0].id;
  const done = { status: 'completed', verifiedBy: 'monet', note: '実物を確認' };
  for (const author of ['agent', 'monet']) assert.equal(thrown(() => change(bare, 'update', done, author, bareId))?.code, 'acceptance_missing');
  // The owner and the flow itself may still withdraw; a plain requirement stays withdrawable by an agent.
  assert.equal(change(record, 'withdraw', {}, 'bridge', id), true);
  const plain = project();
  change(plain, 'add', { title: '台帳の整理', source: 'ai' }, 'agent');
  assert.equal(change(plain, 'withdraw', {}, 'agent', projectRequirements(plain)[0].id), true);
});
