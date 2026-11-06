// Local, synthetic Work UI fixture. Never calls Linear or reads personal data.
import http from 'node:http';
let tasks;
const reset = () => { tasks = [
  { id: 'b9d2f664-cda3-4c56-8d39-c4d6df597254', identifier: 'BUS-TEST1', title: '次の打ち合わせを確認する', description: '資料と開始時刻を確認', dueDate: '2026-11-02', priority: 2, status: 'todo', stateName: 'Todo', updatedAt: '2026-11-02T00:00:00Z', url: null },
  { id: 'dce58a26-2f89-4d6a-b78e-01d07d485dbd', identifier: 'BUS-TEST2', title: '今週の振り返りをまとめる', description: '', dueDate: null, priority: 0, status: 'todo', stateName: 'Todo', updatedAt: '2026-11-01T00:00:00Z', url: null },
]; };
reset();
const send = (res, status, data, headers = {}) => { res.writeHead(status, { 'Content-Type': 'application/json', ...headers }); res.end(JSON.stringify({ data, requestId: 'work-fixture' })); };

// Work sessions for the scroll/header tests. Three states on one fixture:
// empty, waiting for a decision, and a long transcript with an image.
const SESSION_IDS = { empty: 'ses_1111111111111111', decision: 'ses_2222222222222222', long: 'ses_3333333333333333', stale: 'ses_4444444444444444' };
const IMAGE_ID = 'a'.repeat(64);
const FIXTURE_IMAGE = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const fixtureModel = { provider: 'claude', model: 'claude-opus-5-5', effort: 'high' };
const fixtureSession = (id, name, phase, pending = null) => ({
  id, name, nameSource: 'agent', delegateSessionId: `agent-${id}`, requestId: id,
  parentId: null, projectId: null, workspaceId: 'ws_fixture', cwd: '/Users/laa', profile: 'opus-high',
  requested: fixtureModel, observed: fixtureModel, runtimeVerified: true, phase, pending,
  resumedFrom: null, resumedTo: null, instructionVersion: null, instructionHash: null,
  createdAt: '2026-11-06T00:00:00Z', updatedAt: '2026-11-06T00:00:00Z', observedAt: '2026-11-06T00:00:00Z',
  events: { lastSeq: 1, oldestSeq: 1, cursor: 'fixture' },
  observation: { available: true, code: null }, favorite: false, archivedAt: null,
  mode: 'bypass', fast: false, worktree: false, observedFast: true, capabilities: { effort: true },
});
const sessions = [
  fixtureSession(SESSION_IDS.empty, '空の会話', 'awaiting_review'),
  fixtureSession(SESSION_IDS.decision, '判断待ち', 'awaiting_decision', { count: 1, kinds: ['question'] }),
  fixtureSession(SESSION_IDS.long, '長い履歴', 'awaiting_review'),
  // The last read could not reach Paseo: values are the last confirmed ones.
  { ...fixtureSession(SESSION_IDS.stale, '観測失敗', 'awaiting_review'),
    observation: { available: false, code: 'paseo_unavailable' } },
];
const longText = (index) => `## 見出し ${index}\n\n${'本文をここに置きます。'.repeat(12)}\n\n\`\`\`\nlet value = ${index}\n\`\`\`\n\n末尾の行です。  `;
const longMessages = Array.from({ length: 40 }, (_, index) => ({
  id: `fixture-${index}`, role: index % 2 === 0 ? 'user' : 'assistant',
  text: index === 0 ? '最初の依頼です。' : longText(index), timestamp: '2026-11-06T00:00:00Z',
}));
longMessages.push({ id: 'fixture-image', role: 'assistant', text: '', timestamp: '2026-11-06T00:00:00Z', images: [IMAGE_ID] });
const conversationFor = (id) => id === SESSION_IDS.long ? longMessages : [];
// What the app actually fetched, as opposed to what the fixture holds. The UI
// test waits for this before asserting the scroll position, so a stopped
// client cannot pass by accident.
let lastServed = 0;
let imagesServed = 0;
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

const api = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const path = url.pathname;
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
  if (path === '/v1/routines') return send(res, 200, { items: [{ id: 'daily', name: '朝の確認', schedule: '毎日 07:30', destination: 'Cielの定期実行チャット', triggerKind: 'scheduled', state: 'scheduled', lastRunAt: '2026-11-01T22:30:00Z', nextRunAt: null, businessStatus: 'completed', notificationStatus: 'sent', result: '業務終了' }, { id: 'service', name: '常駐の確認用', triggerKind: 'service', schedule: '常駐', state: 'running' }], nextCursor: null });
  if (path === '/v1/skills') return send(res, 200, { items: [{ id: 'test:weekly', name: 'weekly-report', description: '指定した内容から週報を作成します。', category: '日常業務', summary: 'カオナビの週報を作成する', detail: '社長の指定内容に沿って現職の週報を入力します。', source: 'Claude' }], nextCursor: null });
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
  if (path === '/v1/projects') return send(res, 200, { items: [], nextCursor: null });
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
    longMessages.length = 41;
    advanced = 0;
    lastServed = 0;
    imagesServed = 0;
  }
  if (req.url === '/hold-image') holdImages();
  if (req.url === '/release-image') releaseImages();
  if (req.url === '/advance') {
    advanced += 1;
    longMessages.push({ id: `fixture-advanced-${advanced}`, role: 'assistant',
      text: `新着メッセージ ${advanced}`, timestamp: '2026-11-06T00:00:00Z' });
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ messages: longMessages.length, served: lastServed, images: imagesServed }));
});
api.listen(19584, '127.0.0.1'); control.listen(19585, '127.0.0.1');
