// Local, synthetic Work UI fixture. Never calls Linear or reads personal data.
import http from 'node:http';
let tasks;
const reset = () => { tasks = [
  { id: 'b9d2f664-cda3-4c56-8d39-c4d6df597254', identifier: 'BUS-TEST1', title: '次の打ち合わせを確認する', description: '資料と開始時刻を確認', dueDate: '2026-11-02', priority: 2, status: 'todo', stateName: 'Todo', updatedAt: '2026-11-02T00:00:00Z', url: null },
  { id: 'dce58a26-2f89-4d6a-b78e-01d07d485dbd', identifier: 'BUS-TEST2', title: '今週の振り返りをまとめる', description: '', dueDate: null, priority: 0, status: 'todo', stateName: 'Todo', updatedAt: '2026-11-01T00:00:00Z', url: null },
]; };
reset();
const send = (res, status, data) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ data, requestId: 'work-fixture' })); };
const api = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const path = url.pathname;
  if (path === '/v1/devices/enroll') { req.resume(); return send(res, 201, { deviceId: 'work-fixture', token: 'fixture-token', scopes: ['tasks:read', 'tasks:write', 'sessions:read', 'calendar:read', 'calendar:write'] }); }
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
  if (path === '/v1/projects' || path === '/v1/sessions') return send(res, 200, { items: [], nextCursor: null });
  res.writeHead(503, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ error: { code: 'fixture_unavailable', message: 'Fixture unavailable', retryable: false }, requestId: 'fixture' }));
});
const control = http.createServer((req, res) => { if (req.url === '/reset') reset(); res.end('ok'); });
api.listen(19584, '127.0.0.1'); control.listen(19585, '127.0.0.1');
