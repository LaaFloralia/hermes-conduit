// Read-only loopback views of the existing Work and Studio UI fixtures.
// No API address is accepted from an app request and no request can escape localhost.
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createStudioUIFixture } from '../studio-ui-fixture.mjs';

const work = Number(process.argv[2]);
if (!Number.isInteger(work) || work <= 1024 || work >= 65535) throw new Error('Work fixture port required');
const stem = '次の四半期に向けた制作計画と関係者への確認事項をまとめた長い日本語の名前';
const paragraph = '関係者が順番を迷わないよう、変更の理由と確認する箇所を資料にまとめます。';
const titleKeys = new Set(['name', 'title', 'label']);
const bodyKeys = new Set(['text', 'summary', 'description', 'detail', 'details', 'instructions', 'progressNote', 'prompt', 'question', 'reason', 'conditions', 'nextStep']);
function expand(value, key = '') {
  if (Array.isArray(value)) return value.map((x) => expand(x));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, expand(v, k)]));
  if (typeof value !== 'string' || !value || !/[\u3040-\u30ff\u3400-\u9fff]/.test(value)) return value;
  if (titleKeys.has(key)) return `${stem}｜${value}`;
  if (bodyKeys.has(key)) return `${paragraph}${paragraph}\n\n${value}`;
  return value;
}
const ok = (data) => ({ data, requestId: 'capture-fixture' });
const requirements = ['in_progress', 'awaiting_decision', 'not_started', 'completed'].map((status, order) => ({
  id: `req_capture_${order + 1}`, title: ['実窓の余白を比較する', '公開用見本を選ぶ', '操作手順をまとめる', '主要画面を洗い出す'][order],
  details: '初めて読む人が迷わないよう、手元の画面と照らし合わせます。', source: order === 1 ? 'ai' : 'owner', status, order,
  sessionIds: order === 0 ? ['ses_5555555555555555'] : order === 1 ? ['ses_2222222222222222'] : [],
}));
const progress = { requirementSummary: { completed: 1, total: 4 }, progressNote: '撮影手順を確認済み。見本の選択を待っています。' };
const campaign = { key: 'capture-fixture', kind: 'site', category: 'prize', status: 'needs_owner',
  title: '制作資料の見本を受け取る', organizer: '見本の主催者', benefit: '制作ノート',
  conditions: '見本のため応募は行いません。', url: 'https://campaign.example.invalid/' };
const { api, control } = createStudioUIFixture();
const listen = async (server) => { server.listen(0, '127.0.0.1'); await once(server, 'listening'); return server.address().port; };
const studioPort = await listen(api);
const controlPort = await listen(control);
const upstream = (port, path, options) => fetch(`http://127.0.0.1:${port}${path}`, { ...options, redirect: 'error' });
await upstream(controlPort, '/mode/v2');
let response = await upstream(work + 1, '/decisions/normal');
if (!response.ok || !('served' in await response.json())) throw new Error('Work fixture control unavailable');

function json(res, body, status = 200, etag) {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', ...(etag ? { etag } : {}) });
  res.end(JSON.stringify(body));
}

function server(mode) {
  const responded = new Set();
  return createServer(async (req, res) => {
    const path = new URL(req.url, 'http://fixture.invalid').pathname;
    if (req.method !== 'GET') { res.writeHead(405).end(); return; }
    if (path === '/lab/health') { json(res, { mode }); return; }
    if (path === '/lab/observed') { json(res, [...responded].sort()); return; }
    if (mode === 'error') { req.socket.destroy(); return; }
    const calendar = path.startsWith('/v1/calendar/');
    if (mode === 'loading' && calendar) return; // client cancellation closes this request
    if (mode === 'empty' && path === '/v1/calendar/events') { json(res, ok({ items: [] })); return; }
    const send = (body, status, etag) => {
      if (status == null || (status >= 200 && status < 300)) responded.add(path);
      json(res, mode === 'long' ? expand(body) : body, status, etag);
    };
    if (path === '/v1/campaigns') { send(ok({ count: 1, items: [campaign] })); return; }
    try {
      const isStudio = /^\/v1\/(studio|drive)\//.test(path);
      const isProject = path === '/v1/projects/proj_laa_fixture';
      const requestPath = isProject ? '/v1/projects' : req.url;
      const headers = { authorization: 'Bearer fixture-token' };
      if (req.headers.range) headers.range = req.headers.range;
      const reply = await upstream(isStudio ? studioPort : work, requestPath, { headers, signal: AbortSignal.timeout(25_000) });
      if (!reply.headers.get('content-type')?.includes('json')) {
        const hs = Object.fromEntries(['content-type', 'content-range', 'content-length'].flatMap((key) =>
          reply.headers.has(key) ? [[key, reply.headers.get(key)]] : []));
        res.writeHead(reply.status, hs).end(Buffer.from(await reply.arrayBuffer()));
        return;
      }
      let body = await reply.json();
      if (requestPath === '/v1/projects' && body.data?.items) {
        body.data.items = body.data.items.map((p) => ({ ...p, name: '制作の進行確認', ...progress }));
      }
      if (isProject && body.data?.items?.length) {
        body = ok({ ...body.data.items[0], ...progress, requirements, sessions: [], sessionCounts: { active: 0, archived: 0 } });
      }
      if (path === '/v1/sessions' && body.data?.items) {
        const projectIDs = new Set(requirements.flatMap((row) => row.sessionIds));
        body.data.items = body.data.items.map((row) => projectIDs.has(row.id) ? { ...row, projectId: 'proj_laa_fixture' } : row);
        if (new URL(requestPath, 'http://fixture.invalid').searchParams.has('projectId')) {
          body.data.items = body.data.items.filter((row) => row.projectId === 'proj_laa_fixture');
        }
      }
      if (path.endsWith('/conversation') && body.data?.items) {
        // Keep the long conversation, including its real Markdown, but remove
        // the delayed picture-only records so balance and settling are repeatable.
        body.data.items = body.data.items.filter((item) => item.text);
      }
      if (path === '/v1/drive/files' && body.data?.items) {
        body.data.items = body.data.items.map((file) => ({ ...file, name: '制作資料.png' }));
      }
      send(body, reply.status, reply.headers.get('etag'));
    } catch {
      if (!res.headersSent) res.writeHead(502);
      res.end();
    }
  });
}

const modes = ['normal', 'empty', 'loading', 'error', 'long'];
const ports = await Promise.all(modes.map((mode) => listen(server(mode))));
// First line is the parent's handshake; subsequent logs must never include headers or bodies.
console.log(JSON.stringify(Object.fromEntries(modes.map((mode, i) => [mode, ports[i]]))));
