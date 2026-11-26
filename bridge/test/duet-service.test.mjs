import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdirSync, mkdtempSync, rmSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { createDuetClient, duetOrigin } from '../src/duet/client.mjs';
import { createDuetService } from '../src/duet/service.mjs';
import { laneClient } from '../src/lane/client.mjs';
import { LANE_HEADER } from '../src/lane/guard.mjs';

const date = '2026-11-26T00:00:00.000Z';
const now = () => Date.parse(date);
const row = (id) => ({ id: String(id), kind: 'update', title: 'Title <b>as written</b>', body: '<script>is just text</script>', link: null, createdAt: date });

function stateDir(t) {
  const lane = mkdtempSync(join(tmpdir(), 'laa-lane-'));
  const dir = join(lane, 'state');
  mkdirSync(dir, { mode: 0o700 });
  t.after(() => rmSync(lane, { recursive: true, force: true }));
  return dir;
}

async function fakeWorker(t, initial = []) {
  const id = `duet-${randomUUID()}`;
  const token = randomBytes(32).toString('base64url');
  const notes = new Map(), read = new Set(), requests = [], notices = [];
  const data = { items: initial, notes, notices, read, requests, failPull: false, lostAck: false, loseNote: false, rejectNote: false, invalidPull: false };
  const server = createServer(async (req, res) => {
    if (req.headers[LANE_HEADER] !== id) { res.writeHead(421).end(); return; }
    res.setHeader(LANE_HEADER, id);
    const json = (status, body) => res.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify(body));
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/v1/health') { json(req.headers.authorization ? 400 : 200, { lane: id }); return; }
    if (req.headers.authorization !== `Bearer ${token}`) { json(401, { error: 'invalid_token' }); return; }
    requests.push(url.pathname);
    let payload;
    if (req.method === 'POST') {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      payload = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    }
    switch (url.pathname) {
      case '/pull': {
        if (data.failPull) { json(503, { message: 'untrusted text that must not appear in status' }); break; }
        const after = Number(url.searchParams.get('after'));
        json(200, { items: data.invalidPull ? [{ ...row(999), body: 'x'.repeat(4001) }]
          : data.items.filter((item) => Number(item.id) > after).slice(0, 50) });
        break;
      }
      case '/ack':
        data.items = data.items.filter((item) => Number(item.id) > Number(payload.through));
        if (data.lostAck) { data.lostAck = false; res.destroy(); break; }
        json(200, { ok: true });
        break;
      case '/notes':
        if (data.rejectNote) { json(503, {}); break; }
        if (!notes.has(payload.id)) notes.set(payload.id, payload);
        if (data.loseNote) { data.loseNote = false; res.destroy(); break; }
        json(200, { id: payload.id });
        break;
      case '/notes/status': json(200, { read: [...read] }); break;
      default: json(404, {});
    }
  });
  await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const call = laneClient(origin, id);
  const client = createDuetClient({ origin, token, request: (url, options) => call(url.pathname + url.search, options) });
  return { client, data };
}

test('connector URLs accept only the dedicated Workers.dev origin; not_configured stays idle', async (t) => {
  assert.equal(duetOrigin('https://laa-duet-connector.example.workers.dev/mcp'), 'https://laa-duet-connector.example.workers.dev');
  for (const value of [undefined, 'http://laa-duet-connector.example.workers.dev', 'https://example.invalid/mcp',
    'https://laa-duet-connector.example.workers.dev.evil.invalid', 'https://laa-duet-connector.example.workers.dev/pull',
    'https://user@laa-duet-connector.example.workers.dev/mcp', 'https://laa-duet-connector.example.workers.dev/mcp?hidden=yes']) assert.equal(duetOrigin(value), null);
  const service = createDuetService({ dir: stateDir(t), now, notify: () => assert.fail('notify should be idle') });
  await service.poll();
  assert.deepEqual(service.listItems(50), { items: [], status: { configured: false, lastPullAt: null, lastError: 'not_configured' } });
  const note = await service.postNote('<draft> stays local');
  assert.equal(note.state, 'queued');
  assert.equal(service.listNotes()[0].text, '<draft> stays local');
});

test('poll commits plaintext before notification and ACK, and never re-delivers after lost ACK or restart', async (t) => {
  const { client, data } = await fakeWorker(t, [row(1), row(2), row(2)]);
  const dir = stateDir(t);
  const build = () => createDuetService({ dir, client, now, notify: (item) => {
    assert.ok(service.listItems(10).items.some((stored) => stored.id === item.id));
    assert.ok(data.items.some((remote) => remote.id === item.id));
    data.notices.push(item);
  } });
  let service = build();
  data.lostAck = true;
  await service.poll();
  assert.deepEqual(data.notices.map((item) => item.id), ['1', '2']);
  assert.deepEqual(data.items, []);
  assert.deepEqual(service.listItems(1), { items: [row(2)], status: { configured: true, lastPullAt: date, lastError: 'ack_failed' } });
  assert.equal(statSync(join(dir, 'duet-items.json')).mode & 0o777, 0o600);
  service = build();
  data.items.push(row(2), row(3)); // Simulate a stale duplicate alongside a new item.
  const first = service.poll();
  assert.equal(service.poll(), first);
  await first;
  assert.deepEqual(data.notices, [row(1), row(2), row(3)]);
  assert.deepEqual(data.requests, ['/pull', '/ack', '/ack', '/pull', '/ack']);
  assert.deepEqual(service.listItems(10).items.map((item) => item.id), ['3', '2', '1']);
  assert.equal(service.listItems(10).status.lastError, null);
});

test('failed notification blocks ACK but does not repeat notifications already accepted', async (t) => {
  const { client, data } = await fakeWorker(t, [row(1), row(2)]);
  let fail = true;
  const service = createDuetService({ dir: stateDir(t), client, now, notify: (item) => {
    if (item.id === '2' && fail) throw new Error('fixture not yet accepted');
    data.notices.push(item.id);
  } });
  await service.poll();
  assert.deepEqual(data.requests, ['/pull']);
  assert.equal(service.listItems(20).status.lastError, 'notification_unavailable');
  fail = false;
  await service.poll();
  assert.deepEqual(data.requests, ['/pull', '/ack', '/pull']);
  assert.deepEqual(data.notices, ['1', '2']);
});

test('cap keeps the latest 200 already-delivered items and a bad pull cannot corrupt state', async (t) => {
  const { client, data } = await fakeWorker(t, Array.from({ length: 250 }, (_, i) => row(i + 1)));
  const service = createDuetService({ dir: stateDir(t), client, now, notify: () => {} });
  for (let i = 0; i < 5; i++) await service.poll();
  const before = service.listItems(200).items;
  assert.equal(before.length, 200);
  assert.deepEqual([before[0].id, before.at(-1).id], ['250', '51']);
  data.failPull = true;
  await service.poll();
  assert.deepEqual(service.listItems(200), { items: before, status: { configured: true, lastPullAt: date, lastError: 'pull_failed' } });
  data.failPull = false;
  data.invalidPull = true;
  await service.poll();
  assert.deepEqual(service.listItems(200).items, before);
  assert.equal(service.listItems(200).status.lastError, 'pull_failed');
});

test('notes remain queued on rejection or ambiguous send; retry uses the same UUID and marks read', async (t) => {
  const { client, data } = await fakeWorker(t);
  const dir = stateDir(t);
  const open = () => createDuetService({ dir, client, now, notify: () => {} });
  let service = open();
  data.rejectNote = true;
  const first = await service.postNote('a <tag>');
  assert.match(first.id, /^[a-f0-9-]{36}$/);
  assert.equal(first.state, 'queued');
  await service.poll();
  assert.equal(service.listItems(5).status.lastError, 'notes_send_failed');
  data.rejectNote = false;
  data.loseNote = true;
  const second = await service.postNote('other **literal**');
  assert.equal(second.state, 'queued');
  assert.equal(data.notes.size, 1);
  service = open();
  await service.poll();
  assert.equal(data.notes.size, 2);
  assert.deepEqual(service.listNotes().map(({ state }) => state), ['sent', 'sent']);
  assert.deepEqual(data.notes.get(first.id), { id: first.id, text: 'a <tag>' });
  data.read.add(second.id);
  await service.poll();
  assert.deepEqual(service.listNotes()[0], { id: second.id, text: 'other **literal**', state: 'read', createdAt: date });
  assert.equal((await service.postNote('written immediately')).state, 'sent');
});
