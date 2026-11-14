// Local UI harness: the real habits routes and temporary storage, no owner data.
import http from 'node:http';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { habitRoutes } from '../src/routes/habits.mjs';
const dir = mkdtempSync(join(tmpdir(), 'habits-ui-'));
const routes = habitRoutes({ dir });
const server = http.createServer(async (req, res) => {
  try {
    const path = new URL(req.url, 'http://localhost').pathname;
    const route = routes.find(r => r.method === req.method && (r.pattern ? r.pattern.test(path) : r.path === path));
    if (!route) { res.writeHead(404, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ ok: false, error: { code: 'calendar_not_configured' } })); return; }
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    const result = await route.handler({ req, device: { id: 'ui-fixture' }, params: route.pattern?.exec(path)?.slice(1), rawBody: Buffer.concat(chunks) });
    res.writeHead(result.status, { 'Content-Type': 'application/json', ...result.headers }); res.end(JSON.stringify({ data: result.data, requestId: 'ui-fixture' }));
  } catch (e) { res.writeHead(e.status ?? 500, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ ok: false, error: { code: e.code, message: e.message } })); }
});
server.listen(19684, '127.0.0.1', () => console.log('habits UI fixture ready'));
process.on('SIGTERM', () => server.close(() => { rmSync(dir, { recursive: true, force: true }); process.exit(0); }));
