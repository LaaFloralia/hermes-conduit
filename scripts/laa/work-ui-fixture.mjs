// Local, synthetic Work UI fixture. Never calls Linear or reads personal data.
import http from 'node:http';
let tasks;
// The Bridge's run record (contract 2026-11-09). One row is running so the
// completion is refused; the rest cover every label the list draws, plus the
// legacy row with no run at all.
const fixtureRun = (staff, name, state, sessionId = null, sessionRef = null, extra = {}) => ({
  creator: 'owner', assignee: { kind: 'staff', staff, name }, profile: 'opus-high',
  profileLabel: 'Opus 5.5 · High', state, sessionId, sessionRef, decisionRef: null, report: null, error: null, ...extra,
});
let createdBodies = [];
let completed = [];
let lastAnswer = null;
// A Bridge on a device without sessions:write refuses a staff assignee (403
// insufficient_scope). /tasks/refuse-staff switches it on for one test.
let refuseStaffCreate = false;
// Tasks whose completion is refused as changed in Linear (412), so a batch
// of picked tasks meets one failure: /tasks/refuse-complete/<id>.
let refuseComplete = new Set();
const reset = () => {
  createdBodies = []; completed = []; lastAnswer = null; refuseStaffCreate = false; refuseComplete = new Set();
  tasks = [
    { id: 'b9d2f664-cda3-4c56-8d39-c4d6df597254', identifier: 'BUS-TEST1', ref: 'T12', title: '次の打ち合わせを確認する', description: '資料と開始時刻を確認', dueDate: '2026-11-02', priority: 2, status: 'todo', stateName: 'Todo', updatedAt: '2026-11-02T00:00:00Z', url: null,
      run: fixtureRun('monet', 'Monet', 'running', 'ses_5555555555555555', 'S5') },
    { id: 'dce58a26-2f89-4d6a-b78e-01d07d485dbd', identifier: 'BUS-TEST2', ref: 'T13', title: '今週の振り返りをまとめる', description: '', dueDate: null, priority: 3, status: 'todo', stateName: 'Todo', updatedAt: '2026-11-01T00:00:00Z', url: null, run: null },
    { id: '7a1c3d5e-1111-4a2b-9c3d-000000000014', identifier: 'BUS-TEST4', ref: 'T14', title: '見積りを送る', description: '', dueDate: null, priority: 0, status: 'todo', stateName: 'Todo', updatedAt: '2026-11-03T00:00:00Z', url: null,
      run: fixtureRun('cto', 'Ada', 'queued') },
    { id: '7a1c3d5e-1111-4a2b-9c3d-000000000015', identifier: 'BUS-TEST5', ref: 'T15', title: '名刺の紙を決める', description: '', dueDate: null, priority: 0, status: 'todo', stateName: 'Todo', updatedAt: '2026-11-04T00:00:00Z', url: null,
      run: fixtureRun('cio', 'Sherlock', 'awaiting_decision', 'ses_8888888888888888', 'S8') },
    { id: '7a1c3d5e-1111-4a2b-9c3d-000000000016', identifier: 'BUS-TEST6', ref: 'T16', title: '週報の下書き', description: '', dueDate: null, priority: 0, status: 'todo', stateName: 'Todo', updatedAt: '2026-11-05T00:00:00Z', url: null,
      run: fixtureRun('cos', 'Merlin', 'stopped') },
    { id: '7a1c3d5e-1111-4a2b-9c3d-000000000017', identifier: 'BUS-TEST7', ref: 'T17', title: '写真の選定', description: '', dueDate: null, priority: 0, status: 'todo', stateName: 'Todo', updatedAt: '2026-11-06T00:00:00Z', url: null,
      run: fixtureRun('cso', 'Talos', 'failed', null, null, { error: 'unknown_profile' }) },
    { id: '7a1c3d5e-1111-4a2b-9c3d-000000000018', identifier: 'BUS-TEST8', ref: 'T18', title: 'HPの文言', description: '', dueDate: null, priority: 0, status: 'todo', stateName: 'Todo', updatedAt: '2026-11-07T00:00:00Z', url: null,
      run: fixtureRun('argus', 'Argus', 'done', 'ses_3333333333333333', 'S3', { report: { summary: '3案を比較して2案に絞りました。', at: '2026-11-07T00:00:00Z' } }) },
  ];
  if (manyTasks) tasks.push(...manyTaskSeed());
};
// A list the size of the owner's (about thirty open tasks in eight genres),
// for the grouped-list shots: /tasks/many, or WORK_FIXTURE_TASKS=many at
// start. Synthetic titles only. Dates are relative to today so the due
// sections (期限切れ・今日・明日・7日以内) always have rows.
let manyTasks = process.env.WORK_FIXTURE_TASKS === 'many';
const fixtureDay = (offset) => {
  const date = new Date(); date.setDate(date.getDate() + offset);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
};
const manyTaskSeed = () => [
  ['LAAアプリ：タスク一覧をジャンル別に整える', 2, 0, { project: { id: 'project-app', name: 'LAAアプリ' } }],
  ['Chat：社員の切替を速くする', 3, null],
  ['Work：判断ボードの通知を実機で確かめる', 0, 1],
  ['iPhoneのアプリ更新確認の対象を照合する', 0, null],
  ['AI社員の指示書を最新の分担に合わせる', 2, null],
  ['モデル分担の変化に追従する仕組みを作る', 0, null],
  ['Brainの草案を整理して採用内容を確定する', 4, null],
  ['2要素認証の予備手段を確認する', 1, -1],
  ['古いAPIキーを棚卸しして失効させる', 2, 3],
  ['FileVaultの復旧方法を確認する', 0, null],
  ['Mac miniの空き容量を増やす', 3, null],
  ['Time Machine用の外付けSSDを選ぶ', 0, 12],
  ['XAUUSDの反転手法を検証する', 2, null, { labels: [{ id: 'label-trade', name: 'トレード', color: '#86661C' }] }],
  ['損切りの価格帯の仮説を整理する', 0, null],
  ['【法人化】会社形態と設立日を決める', 1, 5],
  ['【法人化】名刺の記載内容を確認する', 0, 2],
  ['PR動画の最新版を作る', 3, 9],
  ['プレイリストとBGMの基準を決める', 4, null],
  ['有給休暇の残りを取得する', 0, 33],
  ['来期のキャリア目標を見直す', 0, null],
  ['日々の記録の置き場を決める', 0, null],
].map(([title, priority, due, extra = {}], index) => ({
  id: `7a1c3d5e-2222-4a2b-9c3d-${String(100 + index).padStart(12, '0')}`,
  identifier: `BUS-MANY${index + 1}`, ref: `T${30 + index}`, title, description: '',
  dueDate: due === null ? null : fixtureDay(due), priority, status: 'todo', stateName: 'Todo',
  updatedAt: `2026-11-${String(10 - (index % 9)).padStart(2, '0')}T00:00:00Z`, url: null,
  run: index === 4 ? fixtureRun('monet', 'Monet', 'running', 'ses_5555555555555555', 'S5')
    : index === 8 ? fixtureRun('cso', 'Talos', 'awaiting_decision', 'ses_8888888888888888', 'S8')
    : index === 16 ? fixtureRun('argus', 'Argus', 'queued') : null,
  ...extra,
}));
reset();
const send = (res, status, data, headers = {}) => { res.writeHead(status, { 'Content-Type': 'application/json', ...headers }); res.end(JSON.stringify({ data, requestId: 'work-fixture' })); };

// Work sessions for the scroll/header tests. Three states on one fixture:
// empty, waiting for a decision, and a long transcript with an image.
const SESSION_IDS = { empty: 'ses_1111111111111111', decision: 'ses_2222222222222222', long: 'ses_3333333333333333',
  stale: 'ses_4444444444444444', running: 'ses_5555555555555555', noFast: 'ses_6666666666666666', readOnlyFast: 'ses_7777777777777777',
  decisionLong: 'ses_8888888888888888', switched: 'ses_9999999999999999', mythos: 'ses_aaaaaaaaaaaaaaaa',
  max: 'ses_bbbbbbbbbbbbbbbb' };
const SESSION_REFS = {
  ses_1111111111111111: 'S1', ses_2222222222222222: 'S2',
  ses_3333333333333333: 'S3', ses_4444444444444444: 'S4',
  ses_5555555555555555: 'S5', ses_6666666666666666: 'S6', ses_7777777777777777: 'S7',
  ses_8888888888888888: 'S8', ses_9999999999999999: 'S9', ses_aaaaaaaaaaaaaaaa: 'S10', ses_bbbbbbbbbbbbbbbb: 'S11',
};
const IMAGE_ID = 'a'.repeat(64);
const FIXTURE_IMAGE = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const fixtureModel = { provider: 'claude', model: 'claude-opus-5-5', effort: 'high' };
const fixtureSession = (id, name, phase, pending = null) => ({
  id, ref: SESSION_REFS[id] ?? null, name, nameSource: 'agent', delegateSessionId: `agent-${id}`, requestId: id,
  parentId: null, projectId: null, workspaceId: 'ws_fixture', cwd: '/Users/laa', profile: 'opus-high',
  requested: fixtureModel, observed: fixtureModel, runtimeVerified: true, phase, pending,
  resumedFrom: null, resumedTo: null, instructionVersion: null, instructionHash: null,
  createdAt: '2026-11-06T00:00:00Z', updatedAt: '2026-11-06T00:00:00Z', observedAt: '2026-11-06T00:00:00Z',
  events: { lastSeq: 1, oldestSeq: 1, cursor: 'fixture' },
  observation: { available: true, code: null }, favorite: false, archivedAt: null,
  mode: 'bypass', fast: false, worktree: false, observedFast: true, capabilities: { effort: true, fast: true, model: true },
});
// The row's own session: running (so it carries the stop control) and on a
// model the options table does not know, so its name is the long raw one.
const longModel = { provider: 'other', model: 'claude-opus-5-5', effort: 'max' };
const sessions = [
  fixtureSession(SESSION_IDS.empty, '空の会話', 'awaiting_review'),
  fixtureSession(SESSION_IDS.decision, '判断待ち', 'awaiting_decision', { count: 1, kinds: ['question'] }),
  fixtureSession(SESSION_IDS.long, '長い履歴', 'awaiting_review'),
  // The last read could not reach Paseo: values are the last confirmed ones.
  { ...fixtureSession(SESSION_IDS.stale, '観測失敗', 'awaiting_review'),
    observation: { available: false, code: 'paseo_unavailable' } },
  { ...fixtureSession(SESSION_IDS.running, '実行中の長い名前の会話', 'running'),
    requested: longModel, observed: longModel, observedFast: false },
  // The daemon reports no Fast value for this model: no pill at all.
  { ...fixtureSession(SESSION_IDS.noFast, 'Fastなし', 'awaiting_review'), observedFast: null },
  // A model with Fast, but this Bridge may not change it: read-only pill.
  // Its applied effort differs from the request, so the mismatch shows.
  { ...fixtureSession(SESSION_IDS.readOnlyFast, 'Fast変更不可', 'awaiting_review'),
    observed: { provider: 'claude', model: 'claude-opus-5-5', effort: 'max' },
    observedFast: true, capabilities: { effort: true, fast: false } },
  // Waiting for a decision at the top of a long transcript.
  fixtureSession(SESSION_IDS.decisionLong, '判断待ち・長い履歴', 'awaiting_decision', { count: 1, kinds: ['question'] }),
  // Started on Fable 5.2; the provider moved it to Opus 4.8 by itself
  // (Claude Code's model_refusal_fallback, 2026-11-11). Running, so the
  // transcript ends with "thinking...".
  { ...fixtureSession(SESSION_IDS.switched, 'モデル自動切替', 'running'), profile: 'fable-high',
    requested: { provider: 'claude', model: 'claude-fable-5-2', effort: 'xhigh' },
    observed: { provider: 'claude', model: 'claude-opus-4-8', effort: 'xhigh' },
    modelChange: { from: { provider: 'claude', model: 'claude-fable-5-2' }, to: { provider: 'claude', model: 'claude-opus-4-8' },
      seenAt: '2026-11-11T07:46:00Z', byOwner: false } },
  // Mythos at XHigh, which the HQ table offers at High only; compacting now.
  { ...fixtureSession(SESSION_IDS.mythos, 'Mythos XHigh', 'running'), profile: 'mythos-high',
    requested: { provider: 'claude', model: 'claude-mythos-5-2', effort: 'xhigh' },
    observed: { provider: 'claude', model: 'claude-mythos-5-2', effort: 'xhigh' } },
  // The deepest setting, on a GPT model.
  { ...fixtureSession(SESSION_IDS.max, 'Max の推論', 'awaiting_review'), profile: 'astra-max',
    requested: { provider: 'codex', model: 'gpt-6-astra', effort: 'max' },
    observed: { provider: 'codex', model: 'gpt-6-astra', effort: 'max' }, observedFast: null },
];
const fable = { provider: 'claude', model: 'claude-fable-5-2' };
const opus48 = { provider: 'claude', model: 'claude-opus-4-8' };
// Each reply carries the model the Bridge saw writing it; the turn before the
// unrequested switch carries none (bridge/src/sessions/model-log.mjs).
const switchedMessages = [
  { id: 'sw-u1', role: 'user', text: '社内向けの説明資料の構成を考えてください。', timestamp: '2026-11-11T07:30:00Z' },
  { id: 'sw-a1', role: 'assistant', text: '構成案を3つ用意しました。目的・読者・所要時間から選べます。', timestamp: '2026-11-11T07:31:00Z', model: fable },
  { id: 'sw-u2', role: 'user', text: '2案目で進めて、表紙の画像も確認して。', timestamp: '2026-11-11T07:40:00Z', images: [IMAGE_ID] },
  { id: 'sw-a2', role: 'assistant', text: '2案目で章立てを作ります。', timestamp: '2026-11-11T07:41:00Z' },
  { id: 'sw-u3', role: 'user', text: '続けてください。', timestamp: '2026-11-11T07:45:30Z' },
  { id: 'sw-a3', role: 'assistant', text: '章ごとの要点を確認しています。', timestamp: '2026-11-11T07:47:00Z', model: opus48 },
  { id: 'sw-a4', role: 'assistant', text: '第2章の図を差し替える案をまとめています。', timestamp: '2026-11-11T07:48:00Z', model: opus48 },
];
const mythosMessages = [
  { id: 'my-u1', role: 'user', text: '防御設定の差分を見てください。', timestamp: '2026-11-12T01:00:00Z' },
  { id: 'my-a1', role: 'assistant', text: '差分を読み、影響の大きい順に並べています。', timestamp: '2026-11-12T01:01:00Z', model: { provider: 'claude', model: 'claude-mythos-5-2' } },
];
const maxMessages = [
  { id: 'mx-u1', role: 'user', text: '来期の計画の前提を洗い出して。', timestamp: '2026-11-12T02:00:00Z' },
  { id: 'mx-a1', role: 'assistant', text: '前提を5つに分けて整理しました。', timestamp: '2026-11-12T02:02:00Z', model: { provider: 'codex', model: 'gpt-6-astra' } },
];
const longText = (index) => `## 見出し ${index}\n\n${'本文をここに置きます。'.repeat(12)}\n\n\`\`\`\nlet value = ${index}\n\`\`\`\n\n末尾の行です。  `;
const shortText = (index) => `短い返答 ${index}。`;
// Sixty-plus turns, long and short mixed, with two pictures low enough to be
// on screen when the conversation opens at its bottom.
const opus55 = { provider: 'claude', model: 'claude-opus-5-5' };
const longMessages = Array.from({ length: 60 }, (_, index) => ({
  id: `fixture-${index}`, role: index % 2 === 0 ? 'user' : 'assistant',
  text: index === 0 ? '最初の依頼です。' : index % 3 === 0 ? shortText(index) : longText(index),
  timestamp: '2026-11-06T00:00:00Z',
  // One picture near the top, for a page parked on a decision card: it is
  // measured while the owner reads the question.
  images: index === 1 ? [IMAGE_ID] : undefined,
  // The Bridge saw Opus 5.5 write every reply (model-log.mjs).
  model: index % 2 === 0 ? undefined : opus55,
}));
longMessages.push({ id: 'fixture-image', role: 'assistant', text: '', timestamp: '2026-11-06T00:00:00Z', images: [IMAGE_ID], model: opus55 });
const LAST_TEXT = '最後のメッセージ S62M';
longMessages.push({ id: 'fixture-last', role: 'assistant', text: LAST_TEXT, timestamp: '2026-11-06T00:00:00Z', model: opus55 });
longMessages.push({ id: 'fixture-image-2', role: 'assistant', text: '', timestamp: '2026-11-06T00:00:00Z', images: [IMAGE_ID], model: opus55 });
// The Bridge sends only the owner's and the AI's messages; tool calls are not
// part of the conversation.
const conversationFor = (id) => ({ [SESSION_IDS.switched]: switchedMessages, [SESSION_IDS.mythos]: mythosMessages,
  [SESSION_IDS.max]: maxMessages })[id] ?? ([SESSION_IDS.long, SESSION_IDS.decisionLong].includes(id) ? longMessages : []);
// What the app actually fetched, as opposed to what the fixture holds. The UI
// test waits for this before asserting the scroll position, so a stopped
// client cannot pass by accident.
// One project gives the Projects list a row with a short number.
const PROJECT = {
  id: 'proj_laa_fixture', ref: 'P1', name: 'LAA', nameSource: 'owner',
  instructions: '共通の指示はここに置きます。', instructionVersion: 1, instructionHash: 'fixture-hash',
  version: 1, etag: '"fixture-project-1"', updatedAt: '2026-11-06T00:00:00Z', archivedAt: null,
  fileCount: 0, files: [],
};
// A PATCH changes a session in place; /reset puts the seed values back so one
// test's toggle cannot leak into the next one's assertions.
const sessionSeed = JSON.parse(JSON.stringify(sessions));
let lastServed = 0;
let imagesServed = 0;
// A slow Mac: the conversation answer takes two seconds, as on a real cold
// read. The session detail stays fast, so the page can be placed before it.
let conversationDelay = 0;
let resetGeneration = 0;
// A held image request lets a test start reading history before the picture
// arrives, instead of racing a fixed delay.
let imageHold = null;
const holdImages = () => {
  if (imageHold) return;
  let release;
  const promise = new Promise((resolve) => { release = resolve; });
  imageHold = { promise, release };
};
const releaseImages = () => {
  if (!imageHold) return;
  imageHold.release();
  imageHold = null;
};
const sessionFor = (id) => sessions.find((session) => session.id === id) ?? null;
// Archive changes the app sent, for the control server's /state.
const archiveRequests = [];
// Follow-ups the app sent, for the control server's /state.
const followUps = [];

// The decision board. Off by default (an empty board) so the hub keeps its
// usual first section for the other Work tests; a test switches it on with
// /decisions/normal, /decisions/empty or /decisions/unsupported (an older
// Bridge without the route), and /decisions/fail-next makes the next answer
// stay undelivered. The first decision carries J1/S4; the others keep ref and
// sourceRef null, as an older Bridge sends.
const DECISION_IDS = { hp: 'dec_0000000000000a01', card: 'dec_0000000000000a02', failed: 'dec_0000000000000a03',
  long: 'dec_0000000000000a04' };
// A production-sized question: about 600 characters of explanation and two
// choices, so the free answer is measured where the owner reads it.
const longSummary = '新しいHPと名刺、写真の選び直しが同時に進んでいます。'.repeat(24) + '公開日と告知の順番を決めると、ここから先の作業を止めずに進められます。';
let decisionMode = 'off';
let failNextDelivery = false;
let loseNextDecisionResponse = false;
let decisionPosts = 0;
let decisions = [];
const iso = (offsetHours) => new Date(Date.now() + offsetHours * 3600 * 1000).toISOString();
const resetDecisions = () => {
  decisionMode = 'off'; failNextDelivery = false; loseNextDecisionResponse = false; decisionPosts = 0;
  decisions = [
    { id: DECISION_IDS.hp, ref: 'J1', status: 'open', title: 'HPの公開日を決める',
      summary: '新しいHPは公開できる状態です。告知の準備に合わせて公開日を1つ選んでください。選んだ日に合わせて告知文と予約投稿を整えます。',
      options: [
        { label: '11月15日（土）に公開', detail: '準備は完了。告知は前日に出します。', recommended: true },
        { label: '11月22日（土）に延期', detail: '写真を撮り直してから公開します。', recommended: false },
        { label: '公開を保留する', detail: null, recommended: false },
      ],
      allowOther: true, impact: '公開日に合わせてSNSの告知予約が決まります。', deadline: iso(5),
      source: { paseoAgentId: 'agent-fixture-hp', sessionId: null, name: 'HP｜公開準備' }, sourceRef: 'S4',
      createdAt: iso(-2), updatedAt: iso(-2), answer: null, delivery: null },
    { id: DECISION_IDS.card, ref: null, status: 'open', title: '名刺の紙を選ぶ',
      summary: '試し刷りの2種から選んでください。',
      options: [
        { label: 'マットな白', detail: '文字がくっきり読めます。', recommended: true },
        { label: '生成りの紙', detail: '柔らかい印象です。', recommended: false },
      ],
      allowOther: true, impact: null, deadline: iso(72),
      source: { paseoAgentId: 'agent-fixture-card', sessionId: null, name: 'Studio｜名刺' }, sourceRef: null,
      createdAt: iso(-5), updatedAt: iso(-5), answer: null, delivery: null },
    { id: DECISION_IDS.failed, ref: null, status: 'answered', title: '週報の送り先を決める',
      summary: '週報をどこへ送るかを決めます。',
      options: [{ label: 'Driveに保存', detail: null, recommended: true }, { label: 'メールの下書き', detail: null, recommended: false }],
      allowOther: true, impact: null, deadline: null,
      source: { paseoAgentId: 'agent-fixture-weekly', sessionId: null, name: '週報｜作成' }, sourceRef: null,
      createdAt: iso(-20), updatedAt: iso(-1),
      answer: { optionIndex: 0, label: 'Driveに保存', note: null, answeredAt: iso(-1), deviceId: 'work-fixture' },
      delivery: { state: 'failed', attempts: 1, messageId: `${DECISION_IDS.failed}:answer:1`, deliveredAt: null, error: 'agent_archived' } },
    { id: DECISION_IDS.long, ref: 'J4', status: 'open', title: '第4四半期の重点を決める',
      summary: longSummary,
      options: [
        { label: '制作を優先し、公開は11月28日', detail: '写真と名刺を先に仕上げます。告知は公開の5日前から。', recommended: true },
        { label: '公開を11月21日に固定', detail: '制作は公開に間に合わせ、足りない分は公開後に足します。', recommended: false },
      ],
      allowOther: true, impact: '公開日から逆算して、写真・名刺・告知の順番が決まります。', deadline: iso(30),
      source: { paseoAgentId: 'agent-fixture-long', sessionId: null, name: 'HP｜四半期計画' }, sourceRef: 'S9',
      createdAt: iso(-1), updatedAt: iso(-1), answer: null, delivery: null },
  ];
};
resetDecisions();
const boardItems = () => {
  if (decisionMode === 'off' || decisionMode === 'empty' || decisionMode === 'unsupported') return [];
  let items = decisions.filter((d) => d.status === 'open' || d.delivery?.state === 'failed').map((d) => ({ kind: 'board', ...d }));
  if (decisionMode === 'long') items = items.filter((d) => d.id === DECISION_IDS.long);
  if (decisionMode !== 'normal' && decisionMode !== 'long') return [];
  if (decisionMode === 'normal') {
    const waiting = sessions.find((session) => session.id === SESSION_IDS.decision);
    items.push({ kind: 'session', sessionId: waiting.id, ref: null, title: waiting.name, summary: 'どちらにしますか？',
      kinds: ['question'], createdAt: iso(-30), deadline: null });
  }
  return items.sort((a, b) => Number(b.delivery?.state === 'failed') - Number(a.delivery?.state === 'failed')
    || (Date.parse(a.deadline) || Infinity) - (Date.parse(b.deadline) || Infinity)
    || Date.parse(b.createdAt) - Date.parse(a.createdAt));
};
const settleDecision = (decision) => {
  const attempts = (decision.delivery?.attempts ?? 0) + 1;
  const failed = failNextDelivery; failNextDelivery = false;
  decision.delivery = { state: failed ? 'failed' : 'delivered', attempts, messageId: `${decision.id}:answer:${attempts}`,
    deliveredAt: failed ? null : new Date().toISOString(), error: failed ? 'delivery_unconfirmed' : null };
  decision.updatedAt = new Date().toISOString();
};

const api = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const path = url.pathname;
  // The usage read is worth watching while the fixture serves it.
  if (path.startsWith('/v1/usage')) console.log('usage', req.method, req.url, req.headers.authorization ? 'auth' : 'no-auth');
  if (path === '/v1/devices/enroll') { req.resume(); return send(res, 201, { deviceId: 'work-fixture', token: 'fixture-token', scopes: ['tasks:read', 'tasks:write', 'sessions:read', 'sessions:write', 'calendar:read', 'calendar:write'] }); }
  if (req.headers.authorization !== 'Bearer fixture-token') { res.writeHead(401); return res.end(); }
  if (path === '/v1/linear-owner-tasks' && req.method === 'GET') return send(res, 200, { items: tasks.filter(t => Boolean(t.archivedAt) === (url.searchParams.get('archived') === 'only')), nextCursor: null });
  if (/^\/v1\/linear-owner-tasks\/[^/]+$/.test(path) && req.method === 'GET') {
    const task = tasks.find(t => t.id === path.split('/').at(-1));
    if (!task) { res.writeHead(404); return res.end(); }
    return send(res, 200, task);
  }
  const completeMatch = path.match(/^\/v1\/linear-owner-tasks\/([^/]+)\/complete$/);
  if (completeMatch && req.method === 'POST') {
    req.resume();
    const task = tasks.find(t => t.id === completeMatch[1]);
    const fail = (status, code, message) => {
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: { code, message, retryable: false }, requestId: 'fixture' }));
    };
    if (!task) return fail(404, 'not_found', 'no such task');
    if (task.run?.state === 'running') return fail(409, 'session_running', 'the session is still working');
    const ifMatch = req.headers['if-match'];
    const key = req.headers['idempotency-key'];
    if (!ifMatch) return fail(428, 'precondition_required', 'If-Match is required');
    if (ifMatch !== task.updatedAt || refuseComplete.has(task.id)) return fail(412, 'precondition_failed', 'the task changed');
    if (!key) return fail(400, 'idempotency_key_required', 'Idempotency-Key is required');
    completed.push({ id: task.id, ifMatch, key, sessionArchived: Boolean(task.run?.sessionId) });
    tasks = tasks.filter(t => t.id !== task.id);
    return send(res, 200, { id: task.id, completed: true, sessionArchived: Boolean(task.run?.sessionId), archive: 'queued' });
  }
  if (path.startsWith('/v1/linear-owner-tasks') && ['POST', 'PATCH', 'DELETE'].includes(req.method)) {
    let raw = ''; for await (const chunk of req) raw += chunk;
    const body = raw ? JSON.parse(raw) : {};
    const action = path.split('/').at(-1);
    const id = ['archive', 'restore'].includes(action) ? path.split('/').at(-2) : action;
    if (['archive', 'restore'].includes(action)) {
      const task = tasks.find(t => t.id === id);
      if (!task) { res.writeHead(404); return res.end(); }
      task.archivedAt = action === 'archive' ? new Date().toISOString() : null;
      task.updatedAt = new Date().toISOString();
      return send(res, 200, { id, archived: action === 'archive' });
    }
    if (req.method === 'POST') {
      if (refuseStaffCreate && body.assignee?.kind === 'staff') {
        res.writeHead(403, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: { code: 'insufficient_scope', message: 'sessions:write is required', retryable: false }, requestId: 'fixture' }));
      }
      createdBodies.push(body);
      const staffNames = { monet: 'Monet', argus: 'Argus', cfo: 'Morgan', cio: 'Sherlock', cos: 'Merlin', cso: 'Talos', cto: 'Ada' };
      const assignee = body.assignee ?? { kind: 'owner' };
      const run = {
        creator: 'owner',
        assignee: assignee.kind === 'staff' ? { kind: 'staff', staff: assignee.staff, name: staffNames[assignee.staff] ?? assignee.staff } : { kind: 'owner' },
        profile: body.profile ?? null,
        profileLabel: body.profile === 'opus-xhigh' ? 'Opus 5.5 · XHigh' : body.profile ? 'Opus 5.5 · High' : null,
        state: assignee.kind === 'staff' ? 'queued' : null,
        sessionId: null, sessionRef: null, decisionRef: null, report: null, error: null,
      };
      const task = { id: body.id, title: body.title, description: body.description, dueDate: body.dueDate,
        priority: body.priority, identifier: `BUS-TEST${tasks.length + 1}`, status: 'todo', stateName: 'Todo',
        updatedAt: new Date().toISOString(), url: null, run };
      tasks.push(task); return send(res, 201, task);
    }
    const task = tasks.find(t => t.id === id);
    if (!task) { res.writeHead(404); return res.end(); }
    Object.assign(task, body, { updatedAt: new Date().toISOString() });
    await new Promise(resolve => setTimeout(resolve, 700));
    return send(res, 200, task);
  }
  if (path === '/v1/decisions' && req.method === 'GET') {
    if (decisionMode === 'unsupported') { res.writeHead(404, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify({ error: { code: 'not_found', message: 'Not found', retryable: false }, requestId: 'fixture' })); }
    return send(res, 200, { items: boardItems(), fetchedAt: new Date().toISOString() });
  }
  const decisionMatch = path.match(/^\/v1\/decisions\/(dec_[0-9a-f]{16})(?:\/(answer|retry))?$/);
  if (decisionMatch) {
    const decision = decisions.find((d) => d.id === decisionMatch[1]);
    if (!decision || decisionMode === 'unsupported') { res.writeHead(404); return res.end(); }
    const { requestId, ...visible } = decision;
    if (!decisionMatch[2] && req.method === 'GET') return send(res, 200, { ...visible });
    if (req.method !== 'POST') { res.writeHead(405); return res.end(); }
    decisionPosts++;
    let raw = ''; for await (const chunk of req) raw += chunk;
    const body = raw ? JSON.parse(raw) : {};
    if (decisionMatch[2] === 'answer') {
      if (decision.status !== 'open') { res.writeHead(409, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify({ error: { code: 'decision_closed', message: 'closed', retryable: false }, requestId: 'fixture' })); }
      const option = Number.isInteger(body.optionIndex) ? decision.options[body.optionIndex] : null;
      lastAnswer = { id: decision.id, optionIndex: Number.isInteger(body.optionIndex) ? body.optionIndex : null,
        note: body.note ?? null };
      decision.status = 'answered';
      // The Bridge stores a free answer in label and leaves note null.
      decision.answer = { optionIndex: option ? body.optionIndex : null, label: option ? option.label : (body.note ?? 'その他'),
        note: option ? (body.note ?? null) : null, answeredAt: new Date().toISOString(), deviceId: 'work-fixture' };
    }
    await new Promise((resolve) => setTimeout(resolve, 600));
    settleDecision(decision);
    if (loseNextDecisionResponse) { loseNextDecisionResponse = false; res.destroy(); return; }
    const { requestId: _, ...result } = decision;
    return send(res, 200, { decision: result });
  }
  if (path === '/v1/routines') return send(res, 200, { items: [{ id: 'daily', ref: 'R1', name: '朝の確認', schedule: '毎日 07:30', destination: 'Monetの定期実行チャット', triggerKind: 'scheduled', state: 'scheduled', lastRunAt: '2026-11-01T22:30:00Z', nextRunAt: null, businessStatus: 'completed', notificationStatus: 'sent', result: '業務終了' }, { id: 'service', ref: 'R2', name: '常駐の確認用', triggerKind: 'service', schedule: '常駐', state: 'running' },
    // The day tree: one routine in each part of the day, an error and a run in progress.
    { id: 'market', ref: 'R3', name: '昼の市況メモ', schedule: '平日 12:00', destination: 'Argusのチャット', triggerKind: 'scheduled', state: 'error', lastRunAt: '2026-11-11T03:00:00Z', nextRunAt: '2026-11-12T12:00:00+09:00', businessStatus: 'failed', notificationStatus: 'failed', result: 'error' },
    { id: 'digest', ref: 'R4', name: '夕方のまとめ', schedule: '毎日 18:30', destination: 'Monetの定期実行チャット', triggerKind: 'scheduled', state: 'running', lastRunAt: '2026-11-10T09:30:00Z', nextRunAt: '2026-11-11T18:30:00+09:00', businessStatus: 'completed' },
    { id: 'backup', ref: 'R5', name: 'Brainの控え', schedule: '毎日 02:00', destination: null, triggerKind: 'scheduled', state: 'scheduled', lastRunAt: '2026-11-10T17:00:00Z', nextRunAt: '2026-11-12T02:00:00+09:00', businessStatus: 'completed', notificationStatus: 'suppressed' },
    { id: 'weekly', ref: 'R6', name: '週報の下書き', schedule: '毎週月曜 09:00', destination: 'Monetの定期実行チャット', triggerKind: 'scheduled', state: 'scheduled', nextRunAt: '2026-11-16T09:00:00+09:00' }], nextCursor: null });
  if (path === '/v1/skills') return send(res, 200, { items: [{ id: 'test:weekly', ref: 'K1', name: 'weekly-report', description: '指定した内容から週報を作成します。', category: '日常業務', summary: 'カオナビの週報を作成する', detail: '社長の指定内容に沿って現職の週報を入力します。', source: 'Claude' }], nextCursor: null });
  if (path.startsWith('/v1/personal-tasks/') && path.split('/').length === 4) {
    const requested = decodeURIComponent(path.split('/').at(-1));
    const found = tasks.find(t => requested === t.id || requested === `linear:${t.identifier}`) || tasks[0];
    return send(res, 200, { viewerId: 'work-fixture', task: {
      id: `linear:${found.identifier}`, sourceId: `linear:${found.identifier}`, linearId: found.id,
      title: found.title, description: found.description,
      owner: { id: 'viewer', name: '社長', kind: 'user' },
      status: { id: 'todo', name: 'Todo', type: 'unstarted' },
      team: { id: 'BUS', name: 'LAA', key: 'BUS' },
      project: found.project ? { id: found.project.id, name: found.project.name } : null, milestone: null, cycle: null, parent: null,
      priority: found.priority, estimate: null, dueDate: found.dueDate,
      labels: (found.labels ?? []).map(({ id, name, color }) => ({ id: id ?? name, name, color })), labelsComplete: true, url: null,
      updatedAt: found.updatedAt } });
  }
  if (path.startsWith('/v1/personal-tasks/') && path.split('/').length > 4) {
    return send(res, 200, { items: [], nextCursor: null, observedAt: '2026-11-02T00:00:00Z', viewerId: 'work-fixture' });
  }
  if (path === '/v1/calendar/calendars') return send(res, 200, { items: [{ id: 'primary', title: 'LAA', color: '#00585E', selected: true, writable: true }] });
  if (path === '/v1/calendar/events') {
    const start = new Date(); start.setHours(10, 0, 0, 0);
    const end = new Date(start.getTime() + 60 * 60 * 1000);
    return send(res, 200, { items: [{ id: 'fixture-event-1', title: 'デザイン確認', start: start.toISOString(), end: end.toISOString(), allDay: false, location: 'LAA', calendarId: 'primary', etag: '"fixture-1"', description: 'MacのToday確認用の予定' }] });
  }
  if (path.startsWith('/v1/calendar/events/')) {
    const start = new Date(); start.setHours(10, 0, 0, 0);
    const end = new Date(start.getTime() + 60 * 60 * 1000);
    return send(res, 200, { id: 'fixture-event-1', title: 'デザイン確認', start: start.toISOString(), end: end.toISOString(), allDay: false, location: 'LAA', calendarId: 'primary', etag: '"fixture-1"', description: 'MacのToday確認用の予定' });
  }
  if (path === '/v1/projects') return send(res, 200, { items: [PROJECT], nextCursor: null });
  if (path === '/v1/usage') {
    // Capacity and one AI window: enough for the bars, the tick and the
    // Settings button check on the Usage screen inside Work.
    const gib = 1073741824;
    const at = (minutes) => new Date(Date.now() - minutes * 60000).toISOString();
    const capacity = (id, used, free, total, status, warning, critical) => ({
      id, kind: 'capacity', label: id, value: used, unit: 'bytes', source: 'filesystem',
      observedAt: at(2), availability: 'available', stale: false, estimated: false, expired: false,
      detail: { totalBytes: total, availableBytes: free, status,
        warningFreeBytes: warning, criticalFreeBytes: critical } });
    return send(res, 200, { items: [
      // One AI window keeps the section honest; the capacity card is what the
      // screenshots compare, so it sits right under it.
      { id: 'provider.claude.weekly', kind: 'quota', label: 'Claude', value: 62, unit: 'percent',
        source: 'codexbar-usage-proxy', observedAt: at(3), availability: 'available', stale: false,
        estimated: false, expired: false,
        detail: { sourceKind: 'proxy', freshUntil: at(-58),
          windows: [{ label: 'weekly', remainingPercent: 62, resetsAt: at(-600), windowMinutes: 10080 }] } },
      capacity('capacity.mac-mini.memory', 18 * gib, 6 * gib, 24 * gib, 'unknown', null, null),
      capacity('capacity.mac-mini.ssd', 360 * gib, 100 * gib, 460 * gib, 'normal', 80 * gib, 40 * gib),
      capacity('capacity.google-drive', 2 * gib, 28 * gib, 30 * gib, 'normal', 3 * gib, 0.6 * gib),
      capacity('capacity.macbook.memory', 12 * gib, 4 * gib, 16 * gib, 'unknown', null, null),
      capacity('capacity.macbook.ssd', 148 * gib, 312 * gib, 460 * gib, 'normal', 80 * gib, 40 * gib),
      { id: 'capacity.icloud', kind: 'capacity', label: 'iCloud', value: null, unit: 'bytes',
        source: 'filesystem', observedAt: null, availability: 'unavailable', nullReason: 'unsupported',
        stale: false, estimated: false, expired: false },
    ], nextCursor: null, fetchedAt: at(1) });
  }
  if (path === '/v1/sessions') {
    const archived = url.searchParams.get('archived') === 'only';
    return send(res, 200, { items: sessions.filter((s) => Boolean(s.archivedAt) === archived), nextCursor: null });
  }
  if (path === '/v1/session-options') return send(res, 200, {
    profiles: [
      { id: 'opus-high', label: 'Claude Opus 5.5', provider: 'claude', model: 'claude-opus-5-5', effort: 'high', fast: true },
      { id: 'opus-xhigh', label: 'Claude Opus 5.5', provider: 'claude', model: 'claude-opus-5-5', effort: 'xhigh', fast: true },
      // A second Claude model, so a running session's menu has a model to switch to.
      { id: 'sonnet-high', label: 'Claude Sonnet 5.5', provider: 'claude', model: 'claude-sonnet-5-5', effort: 'high', fast: false },
      { id: 'fable-high', label: 'Claude Fable 5.2', provider: 'claude', model: 'claude-fable-5-2', effort: 'high', fast: false },
      { id: 'mythos-high', label: 'Claude Mythos 5.2', provider: 'claude', model: 'claude-mythos-5-2', effort: 'high', fast: false },
      { id: 'astra-xhigh', label: 'GPT-6 Astra', provider: 'codex', model: 'gpt-6-astra', effort: 'xhigh', fast: true },
      { id: 'astra-max', label: 'GPT-6 Astra', provider: 'codex', model: 'gpt-6-astra', effort: 'max', fast: true },
      { id: 'dsh-high', label: 'DeepSeek V4.1 Flash', provider: 'dsh', model: 'deepseek-v4.1-flash', effort: 'high', fast: false },
    ],
    defaultProfile: 'opus-high', defaultMode: 'bypass',
  });
  // A follow-up sent while a turn runs: the Bridge holds it (queue) and the
  // conversation does not have it yet, so the app shows its own echo.
  const followUp = path.match(/^\/v1\/sessions\/(ses_[0-9a-f]{16})\/messages$/);
  if (followUp && req.method === 'POST') {
    let raw = ''; for await (const chunk of req) raw += chunk;
    const session = sessionFor(followUp[1]);
    if (!session) { res.writeHead(404); return res.end(); }
    const body = raw ? JSON.parse(raw) : {};
    followUps.push({ session: session.id, chars: (body.message ?? '').length, images: (body.images ?? []).length });
    session.queue = { count: (session.queue?.count ?? 0) + 1, items: [] };
    return send(res, 200, session);
  }
  const sessionMatch = path.match(/^\/v1\/sessions\/(ses_[0-9a-f]{16})(?:\/(initial-instruction|conversation|events|decision|images\/[a-f0-9]{64}))?$/);
  if (sessionMatch) {
    const session = sessionFor(sessionMatch[1]);
    if (!session) { res.writeHead(404); return res.end(); }
    const leaf = sessionMatch[2] ?? '';
    if (leaf === '' && req.method === 'GET') return send(res, 200, session);
    if (leaf === 'initial-instruction') return send(res, 200, { instruction: { text: 'LAAアプリの会話名を整理してください。\n最初の指示の全文です。', createdAt: '2026-11-14T07:00:00Z', source: 'Bridge' } });
    if (leaf === 'conversation') {
      // A request left over from the previous /reset must not update the new
      // test's delivery count when it finally lands.
      const generation = resetGeneration;
      if (conversationDelay) await new Promise((resolve) => setTimeout(resolve, conversationDelay));
      const items = conversationFor(session.id);
      const result = send(res, 200, { items, compacting: session.id === SESSION_IDS.mythos,
        nextCursor: null, sources: null, total: null, fetchedAt: null });
      if (generation === resetGeneration && session.id === SESSION_IDS.long) lastServed = items.length;
      return result;
    }
    if (leaf === 'events') {
      // Keep the app's long poll from spinning while the fixture is open.
      await new Promise((resolve) => setTimeout(resolve, 1200));
      return send(res, 200, { items: [], nextCursor: 'fixture', oldestSeq: 1, headSeq: 1, resyncRequired: false, resyncReason: null });
    }
    if (leaf === 'decision') return send(res, 200, {
      requests: [{ id: 'fixture-question', kind: 'question', name: 'request_user_input_async', detail: '',
        questions: [{ question: 'どちらにしますか？', options: ['A', 'B'] }] }],
      requestHash: 'fixture-hash', expiresAt: Date.now() + 300000,
    });
    if (leaf.startsWith('images/')) {
      // Deliberately slower than the first layout and both re-placement
      // timers. A passing test therefore proves the content-size follow,
      // not a lucky delay. A held request is released by the test.
      const generation = resetGeneration;
      if (imageHold) await imageHold.promise;
      else await new Promise((resolve) => setTimeout(resolve, 8000));
      // Count only a delivery belonging to the current fixture generation;
      // /reset releases old held requests, and their late completion must not
      // be mistaken for the new test's image.
      if (generation === resetGeneration) imagesServed += 1;
      return send(res, 200, { data: FIXTURE_IMAGE, mimeType: 'image/png' },
        { 'Cache-Control': 'no-store' });
    }
  }
  if (/^\/v1\/sessions\/ses_[0-9a-f]{16}$/.test(path) && req.method === 'PATCH') {
    let raw = ''; for await (const chunk of req) raw += chunk;
    const session = sessionFor(path.split('/').at(-1));
    if (!session) { res.writeHead(404); return res.end(); }
    if (raw) {
      const body = JSON.parse(raw);
      if (body.effort) session.observed = { ...session.observed, effort: body.effort };
      if (body.model) {
        session.observed = { ...session.observed, model: body.model };
        session.ownerChanged = { ...(session.ownerChanged ?? {}), model: body.model };
      }
      if (typeof body.fast === 'boolean') session.observedFast = body.fast;
      // Archiving: the Bridge refuses a tree with anything at work (409
      // session_running) and changes nothing; otherwise the row leaves.
      if (typeof body.archived === 'boolean') {
        archiveRequests.push({ id: session.id, archived: body.archived });
        if (body.archived && session.phase === 'running') {
          res.writeHead(409, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: { code: 'session_running', message: 'a session in this tree is still running', retryable: false }, requestId: 'fixture' }));
        }
        session.archivedAt = body.archived ? '2026-11-13T00:00:00Z' : null;
      }
    }
    return send(res, 200, session);
  }
  res.writeHead(503, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ error: { code: 'fixture_unavailable', message: 'Fixture unavailable', retryable: false }, requestId: 'fixture' }));
});
let advanced = 0;
const control = http.createServer((req, res) => {
  if (req.url === '/reset') {
    resetGeneration += 1;
    releaseImages();
    // A full reset also returns the task list to the size the run started with.
    manyTasks = process.env.WORK_FIXTURE_TASKS === 'many';
    reset();
    sessions.forEach((session, index) => {
      Object.keys(session).forEach((key) => { delete session[key] });
      Object.assign(session, JSON.parse(JSON.stringify(sessionSeed[index])));
    });
    longMessages.length = 63;
    followUps.length = 0;
    archiveRequests.length = 0;
    conversationDelay = 0;
    advanced = 0;
    lastServed = 0;
    imagesServed = 0;
    resetDecisions();
  }
  const decisionControl = req.url.match(/^\/decisions\/(normal|empty|unsupported|off|long)$/);
  if (decisionControl) decisionMode = decisionControl[1];
  if (req.url === '/decisions/fail-next') failNextDelivery = true;
  if (req.url === '/decisions/lose-next-response') loseNextDecisionResponse = true;
  // Synthetic J4 lifecycle, using the production schema without production
  // identifiers, text or side effects. An external retry later confirms delivery.
  if (req.url === '/decisions/deliver-saved') {
    for (const decision of decisions.filter((d) => d.delivery?.state === 'failed')) {
      failNextDelivery = false; settleDecision(decision);
      decision.delivery.attempts = 3;
    }
  }
  if (req.url === '/tasks/refuse-staff') refuseStaffCreate = true;
  if (req.url === '/tasks/allow-staff') refuseStaffCreate = false;
  const refuseCompleteMatch = req.url.match(/^\/tasks\/refuse-complete\/([0-9a-f-]+)$/);
  if (refuseCompleteMatch) refuseComplete.add(refuseCompleteMatch[1]);
  if (req.url === '/tasks/many' || req.url === '/tasks/few') { manyTasks = req.url === '/tasks/many'; reset(); }
  if (req.url === '/hold-image') holdImages();
  if (req.url === '/slow-conversation/on') conversationDelay = 2000;
  if (req.url === '/slow-conversation/off') conversationDelay = 0;
  if (req.url === '/release-image') releaseImages();
  if (req.url === '/advance') {
    advanced += 1;
    longMessages.push({ id: `fixture-advanced-${advanced}`, role: 'assistant',
      text: `新着メッセージ ${advanced}`, timestamp: '2026-11-06T00:00:00Z', model: opus55 });
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ messages: longMessages.length, served: lastServed, images: imagesServed, followUps, archiveRequests,
    created: createdBodies, completed, lastAnswer, decisionPosts,
    answered: decisions.filter((d) => d.status === 'answered').map((d) => ({ id: d.id, optionIndex: d.answer?.optionIndex ?? null,
      note: d.answer?.note ?? null, label: d.answer?.label ?? null, delivery: d.delivery?.state ?? null })) }));
});
// WORK_FIXTURE_PORT moves both servers (api, api + 1) when the usual pair is taken.
const apiPort = Number(process.env.WORK_FIXTURE_PORT || 19584);
api.listen(apiPort, '127.0.0.1'); control.listen(apiPort + 1, '127.0.0.1');
