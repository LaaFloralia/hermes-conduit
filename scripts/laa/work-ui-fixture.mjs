// Local, synthetic Work UI fixture. Never calls Linear or reads personal data.
import http from 'node:http';
let tasks;
const reset = () => { tasks = [
  { id: 'b9d2f664-cda3-4c56-8d39-c4d6df597254', identifier: 'BUS-TEST1', ref: 'T12', title: '次の打ち合わせを確認する', description: '資料と開始時刻を確認', dueDate: '2026-11-02', priority: 2, status: 'todo', stateName: 'Todo', updatedAt: '2026-11-02T00:00:00Z', url: null },
  { id: 'dce58a26-2f89-4d6a-b78e-01d07d485dbd', identifier: 'BUS-TEST2', ref: 'T13', title: '今週の振り返りをまとめる', description: '', dueDate: null, priority: 0, status: 'todo', stateName: 'Todo', updatedAt: '2026-11-01T00:00:00Z', url: null },
]; };
reset();
const send = (res, status, data, headers = {}) => { res.writeHead(status, { 'Content-Type': 'application/json', ...headers }); res.end(JSON.stringify({ data, requestId: 'work-fixture' })); };

// Work sessions for the scroll/header tests. Three states on one fixture:
// empty, waiting for a decision, and a long transcript with an image.
const SESSION_IDS = { empty: 'ses_1111111111111111', decision: 'ses_2222222222222222', long: 'ses_3333333333333333',
  stale: 'ses_4444444444444444', running: 'ses_5555555555555555', noFast: 'ses_6666666666666666', readOnlyFast: 'ses_7777777777777777',
  decisionLong: 'ses_8888888888888888' };
const SESSION_REFS = {
  ses_1111111111111111: 'S1', ses_2222222222222222: 'S2',
  ses_3333333333333333: 'S3', ses_4444444444444444: 'S4',
  ses_5555555555555555: 'S5', ses_6666666666666666: 'S6', ses_7777777777777777: 'S7',
  ses_8888888888888888: 'S8',
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
  mode: 'bypass', fast: false, worktree: false, observedFast: true, capabilities: { effort: true, fast: true },
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
];
const longText = (index) => `## 見出し ${index}\n\n${'本文をここに置きます。'.repeat(12)}\n\n\`\`\`\nlet value = ${index}\n\`\`\`\n\n末尾の行です。  `;
const shortText = (index) => `短い返答 ${index}。`;
// Sixty-plus turns, long and short mixed, with two pictures low enough to be
// on screen when the conversation opens at its bottom.
const longMessages = Array.from({ length: 60 }, (_, index) => ({
  id: `fixture-${index}`, role: index % 2 === 0 ? 'user' : 'assistant',
  text: index === 0 ? '最初の依頼です。' : index % 3 === 0 ? shortText(index) : longText(index),
  timestamp: '2026-11-06T00:00:00Z',
  // One picture near the top, for a page parked on a decision card: it is
  // measured while the owner reads the question.
  images: index === 1 ? [IMAGE_ID] : undefined,
}));
longMessages.push({ id: 'fixture-image', role: 'assistant', text: '', timestamp: '2026-11-06T00:00:00Z', images: [IMAGE_ID] });
const LAST_TEXT = '最後のメッセージ S62M';
longMessages.push({ id: 'fixture-last', role: 'assistant', text: LAST_TEXT, timestamp: '2026-11-06T00:00:00Z' });
longMessages.push({ id: 'fixture-image-2', role: 'assistant', text: '', timestamp: '2026-11-06T00:00:00Z', images: [IMAGE_ID] });
// Tool calls are part of the Bridge's conversation but not of what the owner
// reads: the detail must show the messages and no "実行 N件" row.
longMessages.splice(30, 0,
  { id: 'fixture-tool-1', role: 'tool', text: 'ls -la', toolName: 'shell', toolStatus: 'completed', timestamp: '2026-11-06T00:00:00Z' },
  { id: 'fixture-tool-2', role: 'tool', text: 'grep Work', toolName: 'grep', toolStatus: 'failed', timestamp: '2026-11-06T00:00:00Z' });
const conversationFor = (id) => [SESSION_IDS.long, SESSION_IDS.decisionLong].includes(id) ? longMessages : [];
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

// The decision board. Off by default (an empty board) so the hub keeps its
// usual first section for the other Work tests; a test switches it on with
// /decisions/normal, /decisions/empty or /decisions/unsupported (an older
// Bridge without the route), and /decisions/fail-next makes the next answer
// stay undelivered. The first decision carries J1/S4; the others keep ref and
// sourceRef null, as an older Bridge sends.
const DECISION_IDS = { hp: 'dec_0000000000000a01', card: 'dec_0000000000000a02', failed: 'dec_0000000000000a03' };
let decisionMode = 'off';
let failNextDelivery = false;
let decisions = [];
const iso = (offsetHours) => new Date(Date.now() + offsetHours * 3600 * 1000).toISOString();
const resetDecisions = () => {
  decisionMode = 'off'; failNextDelivery = false;
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
  ];
};
resetDecisions();
const boardItems = () => {
  if (decisionMode !== 'normal') return [];
  const items = decisions.filter((d) => d.status === 'open' || d.delivery?.state === 'failed').map((d) => ({ kind: 'board', ...d }));
  const waiting = sessions.find((session) => session.id === SESSION_IDS.decision);
  items.push({ kind: 'session', sessionId: waiting.id, ref: null, title: waiting.name, summary: 'どちらにしますか？',
    kinds: ['question'], createdAt: iso(-30), deadline: null });
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
      const task = { ...body, identifier: 'BUS-TEST3', status: 'todo', stateName: 'Todo', updatedAt: new Date().toISOString(), url: null };
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
    let raw = ''; for await (const chunk of req) raw += chunk;
    const body = raw ? JSON.parse(raw) : {};
    if (decisionMatch[2] === 'answer') {
      if (decision.status !== 'open') { res.writeHead(409, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify({ error: { code: 'decision_closed', message: 'closed', retryable: false }, requestId: 'fixture' })); }
      const option = Number.isInteger(body.optionIndex) ? decision.options[body.optionIndex] : null;
      decision.status = 'answered';
      decision.answer = { optionIndex: option ? body.optionIndex : null, label: option ? option.label : 'その他', note: body.note ?? null,
        answeredAt: new Date().toISOString(), deviceId: 'work-fixture' };
    }
    await new Promise((resolve) => setTimeout(resolve, 600));
    settleDecision(decision);
    const { requestId: _, ...result } = decision;
    return send(res, 200, { decision: result });
  }
  if (path === '/v1/routines') return send(res, 200, { items: [{ id: 'daily', ref: 'R1', name: '朝の確認', schedule: '毎日 07:30', destination: 'Monetの定期実行チャット', triggerKind: 'scheduled', state: 'scheduled', lastRunAt: '2026-11-01T22:30:00Z', nextRunAt: null, businessStatus: 'completed', notificationStatus: 'sent', result: '業務終了' }, { id: 'service', ref: 'R2', name: '常駐の確認用', triggerKind: 'service', schedule: '常駐', state: 'running' }], nextCursor: null });
  if (path === '/v1/skills') return send(res, 200, { items: [{ id: 'test:weekly', ref: 'K1', name: 'weekly-report', description: '指定した内容から週報を作成します。', category: '日常業務', summary: 'カオナビの週報を作成する', detail: '社長の指定内容に沿って現職の週報を入力します。', source: 'Claude' }], nextCursor: null });
  if (path.startsWith('/v1/personal-tasks/') && path.split('/').length === 4) {
    const requested = decodeURIComponent(path.split('/').at(-1));
    const found = tasks.find(t => requested === t.id || requested === `linear:${t.identifier}`) || tasks[0];
    return send(res, 200, { viewerId: 'work-fixture', task: {
      id: `linear:${found.identifier}`, sourceId: `linear:${found.identifier}`, linearId: found.id,
      title: found.title, description: found.description,
      owner: { id: 'viewer', name: '社長', kind: 'user' },
      status: { id: 'todo', name: 'Todo', type: 'unstarted' },
      team: { id: 'BUS', name: 'LAA', key: 'BUS' }, project: null, milestone: null, cycle: null, parent: null,
      priority: found.priority, estimate: null, dueDate: found.dueDate, labels: [], labelsComplete: true, url: null,
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
    return send(res, 200, { items: archived ? [] : sessions, nextCursor: null });
  }
  if (path === '/v1/session-options') return send(res, 200, {
    profiles: [
      { id: 'opus-high', label: 'Claude Opus 5.5', provider: 'claude', model: 'claude-opus-5-5', effort: 'high', fast: true },
      { id: 'opus-xhigh', label: 'Claude Opus 5.5', provider: 'claude', model: 'claude-opus-5-5', effort: 'xhigh', fast: true },
    ],
    defaultProfile: 'opus-high', defaultMode: 'bypass',
  });
  const sessionMatch = path.match(/^\/v1\/sessions\/(ses_[0-9a-f]{16})(?:\/(conversation|events|decision|images\/[a-f0-9]{64}))?$/);
  if (sessionMatch) {
    const session = sessionFor(sessionMatch[1]);
    if (!session) { res.writeHead(404); return res.end(); }
    const leaf = sessionMatch[2] ?? '';
    if (leaf === '' && req.method === 'GET') return send(res, 200, session);
    if (leaf === 'conversation') {
      // A request left over from the previous /reset must not update the new
      // test's delivery count when it finally lands.
      const generation = resetGeneration;
      if (conversationDelay) await new Promise((resolve) => setTimeout(resolve, conversationDelay));
      const items = conversationFor(session.id);
      const result = send(res, 200, { items, nextCursor: null, sources: null, total: null, fetchedAt: null });
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
      if (typeof body.fast === 'boolean') session.observedFast = body.fast;
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
    reset();
    sessions.forEach((session, index) => {
      Object.keys(session).forEach((key) => { delete session[key] });
      Object.assign(session, JSON.parse(JSON.stringify(sessionSeed[index])));
    });
    longMessages.length = 65;
    conversationDelay = 0;
    advanced = 0;
    lastServed = 0;
    imagesServed = 0;
    resetDecisions();
  }
  const decisionControl = req.url.match(/^\/decisions\/(normal|empty|unsupported|off)$/);
  if (decisionControl) decisionMode = decisionControl[1];
  if (req.url === '/decisions/fail-next') failNextDelivery = true;
  if (req.url === '/hold-image') holdImages();
  if (req.url === '/slow-conversation/on') conversationDelay = 2000;
  if (req.url === '/slow-conversation/off') conversationDelay = 0;
  if (req.url === '/release-image') releaseImages();
  if (req.url === '/advance') {
    advanced += 1;
    longMessages.push({ id: `fixture-advanced-${advanced}`, role: 'assistant',
      text: `新着メッセージ ${advanced}`, timestamp: '2026-11-06T00:00:00Z' });
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ messages: longMessages.length, served: lastServed, images: imagesServed,
    answered: decisions.filter((d) => d.status === 'answered').map((d) => ({ id: d.id, optionIndex: d.answer?.optionIndex ?? null, delivery: d.delivery?.state ?? null })) }));
});
// WORK_FIXTURE_PORT moves both servers (api, api + 1) when the usual pair is taken.
const apiPort = Number(process.env.WORK_FIXTURE_PORT || 19584);
api.listen(apiPort, '127.0.0.1'); control.listen(apiPort + 1, '127.0.0.1');
