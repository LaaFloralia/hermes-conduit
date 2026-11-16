// Synthetic session UI server. No daemon, pairing secrets or real data.
import { createServer } from 'node:http';
const stamp = '2026-11-02T10:00:00Z';
const rootID = 'ses_1111111111111111', childID = 'ses_2222222222222222';
let replied = false;
let favorite = true;
let longList = false;
let failLaunch = false;
let launchAttempts = 0;
let launches = [];
const projectID = 'prj_aaaaaaaaaaaa';
let projectArchivedAt = null;
const project = () => ({ id: projectID, name: '試験プロジェクト', nameSource: 'owner', instructionHash: null, instructionVersion: 0, instructions: null,
  fileCount: 0, files: [], version: 1, etag: '"1"', createdAt: stamp, updatedAt: stamp, archivedAt: projectArchivedAt });
const model = { provider: 'codex', model: 'gpt-6.1-sol', effort: 'high' };
const row = (id, name, parentId, phase) => ({ id, name, parentId, requestId: id, workspaceId: 'home', cwd: '/Users/laa', profile: 'sol-high',
  requested: model, observed: model, phase, favorite: id === rootID && favorite,
  pending: { count: phase === 'awaiting_decision' ? 1 : 0 }, createdAt: stamp, updatedAt: stamp,
  capabilities: { model: true }, events: { lastSeq: 1, oldestSeq: 1, cursor: 'fixture' } });
const rows = () => [row(rootID, '移行の動作確認', null, 'running'), row(childID, '子｜資料の確認', rootID, replied ? 'running' : 'awaiting_decision'), ...launches,
  ...(longList ? Array.from({ length: 20 }, (_, i) => row(`ses_${(i + 3).toString(16).padStart(16, '0')}`, `追加の確認 ${i + 1}`, null, 'idle')) : [])];
const send = (res, data, status = 200) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify({ data, requestId: 'paseo-fixture' })); };
export const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1'), path = url.pathname;
  if (path === '/reset') { replied = false; favorite = true; projectArchivedAt = null; longList = url.searchParams.get('long') === '1'; failLaunch = false; launchAttempts = 0; launches = []; return send(res, {}); }
  if (path === '/state') return send(res, { favorite });
  if (path === '/launch/fail' || path === '/launch/ready') { failLaunch = path.endsWith('/fail'); return send(res, {}); }
  if (path === '/launch/state') return send(res, { attempts: launchAttempts, created: launches.length, existing: rows().filter(r => r.id === rootID || r.id === childID).map(r => ({ id: r.id, phase: r.phase })) });
  if (path === '/v1/devices/enroll') { req.resume(); return send(res, { deviceId: 'paseo-fixture', token: 'fixture-paseo', scopes: ['sessions:read', 'sessions:write'] }, 201); }
  if (req.headers.authorization !== 'Bearer fixture-paseo') return send(res, {}, 401);
  if (path === '/v1/sessions') {
    if (req.method === 'POST') {
      let bytes = ''; for await (const chunk of req) bytes += chunk;
      const body = JSON.parse(bytes); launchAttempts++;
      const existing = launches.find(r => r.requestId === body.requestId);
      if (existing) return send(res, existing);
      if (failLaunch) {
        res.writeHead(503, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ error: { code: 'delegation_failed', retryable: true }, requestId: 'paseo-fixture' }));
      }
      const created = { ...row(`ses_${(launches.length + 100).toString(16).padStart(16, '0')}`, '新しい独立した依頼', null, 'running'), requestId: body.requestId };
      launches.push(created); return send(res, created, 201);
    }
    const requestId = url.searchParams.get('requestId');
    return send(res, { items: rows().filter(r => !requestId || r.requestId === requestId), nextCursor: null });
  }
  if (path === '/v1/projects') return send(res, { items: Boolean(projectArchivedAt) === (url.searchParams.get('archived') === 'only') ? [project()] : [], nextCursor: null });
  if (path === `/v1/projects/${projectID}`) {
    if (req.method === 'PATCH') {
      let body = '';
      for await (const chunk of req) body += chunk;
      projectArchivedAt = JSON.parse(body).archived ? stamp : null;
    }
    return send(res, project());
  }
  if (path === '/v1/session-options') return send(res, { profiles: [{ id: 'sol-high', label: 'GPT-6.1 Sol High', provider: 'codex', model: 'gpt-6.1-sol', effort: 'high', fast: false }, { id: 'muse-high', label: 'Muse（Muse Code未導入のため使えません）', provider: 'muse', model: 'muse', effort: 'high', fast: false, available: false, usageNote: '無料MuseはChatの「薬用石鹸」で使います。\n公開情報のみ・道具なし・直列・遅延あり。\nSessionごとの履歴分離には未対応です。' }], defaultProfile: 'sol-high', defaultMode: 'default' });
  const id = path.split('/')[3], current = rows().find(x => x.id === id);
  if (current) {
    if (req.method === 'PATCH' && path === `/v1/sessions/${rootID}`) {
      let body = '';
      for await (const chunk of req) body += chunk;
      const change = JSON.parse(body);
      if (typeof change.favorite === 'boolean') favorite = change.favorite;
      return send(res, rows()[0]);
    }
    if (path.endsWith('/conversation')) return send(res, { items: [{ id: 'm1', role: 'user', text: '資料を確認してください。' }, { id: 'm2', role: 'assistant', text: replied ? 'A案で進めます。' : '構成を確認しました。次の方針を選んでください。' }] });
    if (path.endsWith('/decision')) return send(res, { requestHash: 'fixture-hash', expiresAt: Date.now() + 300000, requests: replied ? [] : [{ id: 'question-1', kind: 'question', name: 'request_user_input_async', detail: '{}', questions: [{ question: 'どちらの構成で進めますか？', options: ['A案', 'B案'] }] }] });
    if (path.endsWith('/reply')) { req.resume(); replied = true; return send(res, rows().find(x => x.id === id)); }
    if (path.endsWith('/artifacts')) return send(res, { items: [], nextCursor: null });
    if (path.endsWith('/events')) { await new Promise(r => setTimeout(r, 1000)); return send(res, { items: [], nextCursor: 'fixture', headSeq: 1, oldestSeq: 1, resyncRequired: false }); }
    return send(res, current);
  }
  return send(res, { items: [], nextCursor: null });
}).listen(19596, '127.0.0.1');
