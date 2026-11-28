import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseDesign, parseMeetingReply, parseSlip, parseVerdict } from '../src/flow/parse.mjs';
import { loadFlowConfig, needsAdvisor, pickAdvisor, validateFlowConfig } from '../src/flow/config.mjs';
import { parseRoster, pickStaff } from '../src/flow/staffing.mjs';
import { advisorTask, clipBytes, packageTask, staffPrompt } from '../src/flow/prompts.mjs';

const fenced = (value) => `設計です。\n\n\`\`\`json\n${JSON.stringify(value, null, 1)}\n\`\`\`\n`;
const design = (over = {}) => ({ schema: 'laa.design.v1', summary: '一覧に件数を出す',
  requirements: [{ title: '件数を出す', details: '一覧の見出しに件数', acceptance: [{ id: 'a1', text: '見出しに件数が出る', check: 'アプリで一覧を開く' }] }],
  packages: [{ id: 'wp1', requirement: 0, title: 'Bridge｜件数を返す', profile: 'opus-medium', repo: '/Users/laa/dev/hermes-conduit', owns: ['bridge/src/x.mjs'], after: [],
    purpose: 'count', completion: 'count returned', scope: 'bridge only', prompt: 'add the count', verification: 'node --test' }],
  risks: ['none'], ownerDecisions: [], ...over });
const profiles = { allowedProfiles: ['opus-medium', 'opus-high', 'deepseek-flash-high'], defaultProfile: 'opus-medium' };

test('hand-off slip: fields, the last RESULT wins, a missing slip is reported as missing', () => {
  const text = '作業しました。\n\nRESULT: partial\nRESULT: done\nCHANGED: bridge/src/x.mjs — 3f89350\nVERIFIED: node --test — 12 pass\n  second line\nRESIDUAL: none\nNEEDS_OWNER: none';
  const parsed = parseSlip(text);
  assert.equal(parsed.present, true);
  assert.equal(parsed.result, 'done');
  assert.equal(parsed.slip.CHANGED, 'bridge/src/x.mjs — 3f89350');
  assert.equal(parsed.slip.VERIFIED, 'node --test — 12 pass\nsecond line');
  assert.equal(parsed.needsOwner, false);
  assert.equal(parseSlip('終わりました。').present, false);
  assert.equal(parseSlip('RESULT: blocked\nNEEDS_OWNER: money — 課金してよいか — yes/no — no').needsOwner, true);
});

test('meeting reply: the protocol block plus scope and acceptance bullets', () => {
  const { ok, reply } = parseMeetingReply('POSITION: go — 実現できる\nEVIDENCE: src を読んだ\nSCOPE: Bridge のみ\nRISK: 既存の一覧が遅くなる\nALTERNATIVE: none\nASK: none\nACCEPTANCE:\n- 件数が出る\n- テストが通る\n');
  assert.equal(ok, true);
  assert.equal(reply.position, 'go — 実現できる');
  assert.equal(reply.scope, 'Bridge のみ');
  assert.deepEqual(reply.acceptance, ['件数が出る', 'テストが通る']);
  assert.equal(parseMeetingReply('すみません、わかりません').ok, false);
});

test('design: the last valid block is used and bounded', () => {
  const parsed = parseDesign(`\`\`\`json\n{"schema":"other"}\n\`\`\`\n${fenced(design())}`, profiles);
  assert.equal(parsed.ok, true);
  assert.equal(parsed.design.packages[0].profile, 'opus-medium');
  assert.equal(parsed.design.requirements[0].acceptance[0].check, 'アプリで一覧を開く');
  assert.equal(parseDesign('no block here', profiles).error, 'design_block_missing');
});

test('design: a retired or unknown route falls back to the configured profile', () => {
  for (const profile of ['swe-high', 'sol-high', 'astra-max', 'neon-high', undefined]) {
    const parsed = parseDesign(fenced(design({ packages: [{ ...design().packages[0], profile }] })), profiles);
    assert.equal(parsed.ok, true);
    assert.equal(parsed.design.packages[0].profile, 'opus-medium');
  }
  assert.equal(parseDesign(fenced(design({ packages: [{ ...design().packages[0], profile: 'deepseek-flash-high' }] })), profiles).design.packages[0].profile, 'deepseek-flash-high');
});

test('design: refused shapes', () => {
  const pkg = design().packages[0];
  const bad = (over) => parseDesign(fenced(design(over)), profiles);
  assert.equal(bad({ packages: [{ ...pkg, repo: '/etc' }] }).error, 'package_wp1_repo_outside_root');
  assert.equal(bad({ packages: [{ ...pkg, after: ['wp9'] }] }).error, 'package_wp1_after_unknown');
  assert.equal(bad({ packages: [{ ...pkg, after: ['wp2'] }, { ...pkg, id: 'wp2', after: ['wp1'] }] }).error, 'package_order_cycle');
  assert.equal(bad({ packages: [pkg, pkg] }).error, 'package_ids_not_distinct');
  assert.equal(bad({ requirements: [{ title: '受入なし', acceptance: [] }] }).error, 'requirement_0_acceptance_count_invalid');
  assert.equal(bad({ requirements: [...design().requirements, { title: '宙に浮く要件', acceptance: [{ text: 'x' }] }] }).error, 'requirement_1_has_no_package');
  assert.equal(bad({ packages: [{ ...pkg, prompt: '' }] }).error, 'package_prompt_required');
  assert.equal(bad({ ownerDecisions: [{ title: '色', options: ['赤'] }] }).error, 'decision_options_invalid');
});

test('verdict: each kind carries what applying it needs', () => {
  assert.equal(parseVerdict({ verdict: 'verified', note: '実物を確認', acceptance: [{ id: 'a1', status: 'passed' }] }).verdict, 'verified');
  assert.throws(() => parseVerdict({ verdict: 'verified' }), /verdict_note_required/);
  assert.throws(() => parseVerdict({ verdict: 'verified', note: '確認', acceptance: [{ id: 'a1', status: 'failed' }] }), /verified_with_failed_item/);
  assert.throws(() => parseVerdict({ verdict: 'rework' }), /followup_required/);
  assert.throws(() => parseVerdict({ verdict: 'needs_owner', note: '確認' }), /decision_required/);
  assert.throws(() => parseVerdict({ verdict: 'approved' }), /verdict_invalid/);
  assert.throws(() => parseVerdict({ verdict: 'noted', extra: 1 }), /verdict_field_unknown/);
  assert.throws(() => parseVerdict({ verdict: 'noted', note: '二行\nです' }), /verdict_note_invalid/);
  const owner = parseVerdict({ verdict: 'needs_owner', note: '色が決まらない', decision: { title: '色', options: ['赤', '青'], recommended: 1, impact: '【必ず社長：ブランドの好み】色' } });
  assert.deepEqual(owner.decision.options, ['赤', '青']);
  assert.equal(owner.decision.summary, '色が決まらない');
  assert.deepEqual(parseVerdict({ verdict: 'noted', report: { result: '完了  です', verification: 'x' } }).report, { result: '完了 です', verification: 'x', residual: '' });
});

test('config: Mythos advises today; Neon is listed, switched off, with its reason', () => {
  const config = loadFlowConfig({ file: '/nonexistent/requirement-flow.json' });
  assert.deepEqual(config.advisorProfiles.map((item) => [item.profile, item.enabled]), [['mythos-high', true], ['neon-high', false]]);
  assert.match(config.advisorProfiles[1].reason, /waiting for contract/);
  assert.equal(pickAdvisor(config), 'mythos-high');
  assert.equal(pickAdvisor(config, { after: 'mythos-high' }), null);
  assert.equal(config.implementation.defaultProfile, 'opus-medium');
  assert.ok(config.implementation.allowedProfiles.includes('deepseek-flash-high'));
  assert.equal(needsAdvisor(config, { size: 'S', risk: [] }), false);
  assert.equal(needsAdvisor(config, { size: 'S', risk: ['money'] }), true);
  assert.equal(needsAdvisor(config, { size: 'M', risk: [] }), true);
});

test('config: retired routes and unexplained switches are refused; a broken override keeps the defaults', () => {
  const base = JSON.parse(JSON.stringify(loadFlowConfig({ file: '/nonexistent' })));
  const raw = (over) => ({ ...base, advisorProfiles: base.advisorProfiles.map((item) => ({ ...item })), ...over });
  for (const profile of ['swe-high', 'sol-high', 'astra-xhigh', 'gpt-6.2-sol-api-high', 'devin-neon-high', 'terra-fast', 'luna-high']) {
    assert.throws(() => validateFlowConfig(raw({ implementation: { defaultProfile: profile, allowedProfiles: [profile] } })), /allowedProfiles_invalid/);
    assert.throws(() => validateFlowConfig(raw({ advisorProfiles: [{ profile, enabled: true }] })), /advisorProfile_invalid/);
  }
  assert.throws(() => validateFlowConfig(raw({ advisorProfiles: [{ profile: 'mythos-high', enabled: true }, { profile: 'neon-high', enabled: false }] })), /neon-high_reason_required/);
  assert.throws(() => validateFlowConfig(raw({ advisorProfiles: [{ profile: 'neon-high', enabled: false, reason: 'x' }] })), /none_enabled/);
  const dir = mkdtempSync(join(tmpdir(), 'flow-config-'));
  try {
    const file = join(dir, 'requirement-flow.json');
    writeFileSync(file, JSON.stringify({ maxRework: 1, implementation: { defaultProfile: 'opus-high' } }));
    const merged = loadFlowConfig({ file });
    assert.equal(merged.maxRework, 1);
    assert.equal(merged.implementation.defaultProfile, 'opus-high');
    assert.deepEqual(merged.problems, []);
    writeFileSync(file, JSON.stringify({ implementation: { defaultProfile: 'swe-max', allowedProfiles: ['swe-max'] } }));
    const kept = loadFlowConfig({ file });
    assert.equal(kept.implementation.defaultProfile, 'opus-medium');
    assert.match(kept.problems[0], /override_ignored/);
    // Switching the adviser to Neon after the contract is one edit.
    writeFileSync(file, JSON.stringify({ advisorProfiles: [{ profile: 'neon-high', enabled: true }, { profile: 'mythos-high', enabled: true }] }));
    assert.equal(pickAdvisor(loadFlowConfig({ file })), 'neon-high');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

const ROSTER = `version: 1
roles:
  - id: monet
    name: Monet
    company: { seat: chair, work: [orchestration], lens: "依頼の整理" }
  - id: cto
    name: Ada
    title: 開発・インフラ・検証
    company: { seat: member, work: [implementation, review], lens: "実現性・保守の重さ・失敗時の挙動" }
    status: standby          # comment
  - id: cfo
    name: Morgan
    company: { seat: member, work: [judgment], lens: "費用・資金への影響" }
    confidential: true
  - id: cos
    name: Merlin
    company: { seat: member, work: [simple, bulk], lens: "依存の順番・滞留・完了の証拠" }
  - id: cio
    name: Sherlock
    company: { seat: member, work: [x_research], lens: "外部環境の事実" }
  - id: argus
    name: Argus
    company: { seat: member, work: [trade], lens: "無効条件・損失の上限" }
  - id: cso
    name: Talos
    company: { seat: member, work: [security], lens: "権限・秘密・外部への出口" }
  - id: researcher
    name: Fermi
    company: { seat: internal, work: [subagent], lens: "一次情報" }
`;

test('staffing: members only, chosen by risk and wording, the same request always the same staff', () => {
  const roster = parseRoster(ROSTER);
  assert.deepEqual(roster.map((role) => role.id), ['monet', 'cto', 'cfo', 'cos', 'cio', 'argus', 'cso', 'researcher']);
  assert.equal(roster.find((role) => role.id === 'cto').lens, '実現性・保守の重さ・失敗時の挙動');
  assert.equal(roster.find((role) => role.id === 'cfo').confidential, true);
  const pick = (request, extra = {}) => pickStaff({ request, roster, ...extra });
  const app = pick({ title: 'Work一覧に件数を出す', details: 'アプリの画面を直す', repo: '/Users/laa/dev/hermes-conduit' });
  assert.deepEqual(app.map((row) => row.role), ['cto', 'cos']);
  assert.equal(app[0].profile, 'laa-cto');
  const money = pick({ title: '定額プランを見直す', details: null }, { risk: ['money', 'trade', 'auth'], size: 'L' });
  assert.deepEqual(money.map((row) => row.role), ['cfo', 'argus', 'cso']);
  assert.equal(money.find((row) => row.role === 'cfo').titleOnly, true);
  assert.equal(money.find((row) => row.role === 'cso').titleOnly, false);
  const many = pick({ title: 'コードを直し、費用を調査して比較し、権限と順番を整理、売買の記録も', details: null }, { size: 'L' });
  assert.equal(many.length, 4);
  assert.ok(!many.some((row) => ['monet', 'researcher'].includes(row.role)));
  assert.deepEqual(pick({ title: 'お礼の文面', details: null }, { size: 'S' }).map((row) => row.role), ['cto', 'cos']);
  assert.deepEqual(pick({ title: 'コードを直す', details: null }), pick({ title: 'コードを直す', details: null }));
  assert.deepEqual(pickStaff({ request: { title: 'x' }, roster: [] }), []);
});

test('prompts: the confidential member gets the title only; briefs carry the hand-off contract and stay inside the byte limit', () => {
  const flow = { id: 'flw_000000000001', size: 'M', risk: ['money'], request: { title: '定額を見直す', details: '内訳: 秘密の金額 12,345円', repo: null }, staff: [] };
  const cfo = staffPrompt({ member: { role: 'cfo', name: 'Morgan', lens: '費用', titleOnly: true }, flow });
  assert.ok(!cfo.includes('12,345'));
  assert.ok(cfo.includes('定額を見直す') && cfo.includes('ACCEPTANCE:'));
  assert.ok(staffPrompt({ member: { role: 'cto', name: 'Ada', lens: '実現性', titleOnly: false }, flow }).includes('12,345'));
  const config = loadFlowConfig({ file: '/nonexistent' });
  const big = { ...flow, request: { ...flow.request, details: 'あ'.repeat(2700), ownerText: 'い'.repeat(2700) } };
  const advisor = advisorTask({ flow: big, config });
  assert.ok(Buffer.byteLength(advisor.prompt) <= 16_384);
  assert.ok(advisor.prompt.includes('laa.design.v1') && advisor.prompt.includes('opus-medium, opus-high, deepseek-flash-high, deepseek-flash-max'));
  assert.ok(!/swe-|sol-|astra|gpt/i.test(advisor.prompt));
  const brief = packageTask({ pkg: { id: 'wp1', title: 'Bridge｜件数', prompt: 'do it', repo: '/Users/laa/dev/hermes-conduit', owns: ['bridge/src/x.mjs'], after: [], purpose: 'p', completion: 'c', scope: 's', verification: 'node --test' },
    design: { summary: '要約' }, requirement: { title: '件数を出す', acceptance: [{ id: 'a1', text: '件数が出る', check: '一覧を開く' }] }, decisions: [{ title: '色', answer: '青' }] });
  for (const needle of ['TASK: Bridge｜件数', 'OWNED FILES', '- bridge/src/x.mjs', 'DONE CONDITION: c', 'a1: 件数が出る — check: 一覧を開く', 'VERIFICATION YOU MUST RUN BEFORE RETURNING: node --test', 'RESULT: done | partial | blocked', '- 色: 青']) {
    assert.ok(brief.prompt.includes(needle), needle);
  }
  assert.equal(clipBytes('あいうえお', 9), 'あい…');
  assert.equal(Buffer.byteLength(clipBytes('あ'.repeat(100), 30)) <= 30, true);
});
