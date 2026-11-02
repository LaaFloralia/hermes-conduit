import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGoogleConnection } from '../src/google/connection.mjs';
import { createGoogleDrive } from '../src/drive/google.mjs';
import { createGoogleCalendar } from '../src/calendar/google.mjs';
import { createCalendarReminders } from '../src/calendar/reminders.mjs';
import { startBridge } from './helpers.mjs';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { DEFAULT_SCOPES } from '../src/config.mjs';

const credential = { client_id: 'fixture', client_secret: 'fixture-secret', refresh_token: 'fixture-refresh' };
const json = (value, status = 200, headers = {}) => new Response(JSON.stringify(value), { status, headers });
const file = { id: 'file123', name: 'Test.pdf', mimeType: 'application/pdf', size: '8', version: '1', capabilities: { canDownload: true } };
function mockConnection(handler) {
  const calls = [];
  return { calls, accessToken: async () => ({ calendarId: 'primary' }), json: r => r.json(), request: async (url, options = {}, area) => {
    calls.push({ url: new URL(url), options, area }); return handler(new URL(url), options, calls.length);
  } };
}
const draft = { calendarId: 'primary', title: '予定', start: '2026-11-02T10:00:00+09:00', end: '2026-11-02T11:00:00+09:00', timeZone: 'Asia/Tokyo', allDay: false };

test('one OAuth refresh is shared across concurrent Drive and Calendar reads; targets and errors do not leak credentials', async () => {
  let tokens = 0;
  const connection = createGoogleConnection({ env: {}, readCredential: async () => credential, fetchImpl: async url => {
    const u = new URL(url);
    if (u.hostname === 'oauth2.googleapis.com') { tokens++; return json({ access_token: 'fixture-access', expires_in: 3600 }); }
    return json(u.pathname.includes('/drive/') ? { files: [file] } : { items: [] });
  } });
  await Promise.all([createGoogleDrive({ connection }).list(), createGoogleCalendar({ connection }).list({ start: draft.start, end: draft.end })]);
  assert.equal(tokens, 1);
  await assert.rejects(connection.request('https://example.org/leak'), e => e.code === 'google_url_invalid');
});

test('Drive API maps shared drives, shared items, recent, stars, escaped full text and opaque pagination', async () => {
  const connection = mockConnection(url => json(url.pathname.endsWith('/drives') ? { drives: [{ id: 'drive123', name: 'Team' }], nextPageToken: 'drive-next' } : { files: [file], nextPageToken: 'next', incompleteSearch: true }));
  const drive = createGoogleDrive({ connection });
  const shared = await drive.list({ view: 'shared' });
  assert.equal(shared.items[0].kind, 'folder'); assert.equal(shared.nextPageToken, 'drive-next');
  for (const view of ['my','sharedWithMe','recent','starred']) {
    const page = await drive.list({ view, query: "a'b\\c", pageToken: 'opaque' });
    const u = connection.calls.at(-1).url;
    assert.equal(u.searchParams.get('pageToken'), 'opaque');
    assert.ok(u.searchParams.get('q').includes("a\\'b\\\\c"));
    assert.equal(page.items[0].downloadable, true); assert.equal(page.items[0].version, '1');
    assert.equal(page.incompleteSearch, true);
    if (view === 'sharedWithMe') assert.ok(u.searchParams.get('q').includes('sharedWithMe = true'));
    if (view === 'starred') assert.ok(u.searchParams.get('q').includes('starred = true'));
    if (view === 'recent') assert.ok(u.searchParams.get('orderBy').startsWith('viewedByMeTime'));
    if (view === 'my') assert.ok(!u.searchParams.get('q').includes('in parents'));
  }
  await drive.list({ folderId: 'folder123' });
  assert.ok(connection.calls.at(-1).url.searchParams.get('q').includes("'folder123' in parents"));
});

test('Drive forwards Range without buffering videos, exports PDF and never follows arbitrary thumbnail targets', async () => {
  let thumb = 'https://evil.example/image';
  const connection = mockConnection((url, options) => {
    if (url.searchParams.get('fields') === 'thumbnailLink') return json({ thumbnailLink: thumb });
    if (url.pathname.endsWith('/export')) return new Response('%PDF-fixture');
    return new Response('abcd', { status: 206, headers: { 'content-range': 'bytes 0-3/8' } });
  });
  const drive = createGoogleDrive({ connection });
  const opened = await drive.open('file123', { range: 'bytes=0-3' });
  let bytes = ''; for await (const chunk of opened.stream) bytes += chunk;
  assert.equal(bytes, 'abcd'); assert.equal(opened.status, 206);
  assert.equal(connection.calls[0].options.headers.range, 'bytes=0-3');
  assert.equal((await drive.exportPdf('file123')).body.toString(), '%PDF-fixture');
  assert.equal(await drive.thumbnail('file123'), null);
  assert.ok(!connection.calls.some(c => c.url.hostname === 'evil.example'));
});

test('resumable uploads bind to the device, validate offset and commit only on final acknowledgement', async () => {
  const chunkSize = 256 * 1024;
  const connection = mockConnection((url, options) => {
    if (options.method === 'POST') return new Response(null, { status: 200, headers: { location: 'https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture' } });
    if (options.headers['content-range'].startsWith('bytes 0-')) return new Response(null, { status: 308, headers: { range: `bytes=0-${chunkSize-1}` } });
    return json(file);
  });
  const drive = createGoogleDrive({ connection });
  const upload = await drive.beginUpload({ name: 'test.pdf', mimeType: 'application/pdf', size: chunkSize + 4, deviceId: 'owner' });
  assert.equal(JSON.stringify(upload).includes('upload_id'), false);
  await assert.rejects(drive.uploadChunk({ id: upload.id, offset: 0, body: Buffer.alloc(chunkSize), deviceId: 'other' }), e => e.code === 'upload_expired');
  await assert.rejects(drive.uploadChunk({ id: upload.id, offset: 1, body: Buffer.alloc(chunkSize), deviceId: 'owner' }), e => e.code === 'upload_offset_invalid');
  assert.equal((await drive.uploadChunk({ id: upload.id, offset: 0, body: Buffer.alloc(chunkSize), deviceId: 'owner' })).completed, false);
  const done = await drive.uploadChunk({ id: upload.id, offset: chunkSize, body: Buffer.alloc(4), deviceId: 'owner' });
  assert.equal(done.completed, true); assert.equal(done.item.id, file.id);
  assert.equal((await drive.uploadStatus({ id: upload.id, deviceId: 'owner' })).completed, true);
});

test('calendar edits require opt-in write scope, idempotency, etag and valid dates; no real data is written', async t => {
  const calls = [];
  const bridge = await startBridge({ calendar: { service: { save: async p => { calls.push(p); return { id: 'fixture', ...p.event }; }, remove: async p => { calls.push(p); return { deleted: true }; } } } });
  t.after(() => bridge.close());
  assert.ok(!DEFAULT_SCOPES.includes('calendar:write')); assert.ok(!DEFAULT_SCOPES.includes('media:write'));
  const read = await bridge.token(['calendar:read']);
  assert.equal((await bridge.request('/v1/calendar/events', { method: 'POST', token: read, body: draft, key: 'key' })).status, 403);
  const token = await bridge.token(['calendar:read','calendar:write']);
  const post = { method: 'POST', token, body: { ...draft, recurrence: ['RRULE:FREQ=WEEKLY;COUNT=4'], attendees: [{ email: 'fixture@example.com' }], reminderMinutes: 10 }, key: 'create-one' };
  assert.equal((await bridge.request('/v1/calendar/events', post)).status, 201);
  assert.equal((await bridge.request('/v1/calendar/events', post)).status, 201);
  assert.equal(calls.length, 1); assert.match(calls[0].key, /^[a-f0-9]{64}$/);
  assert.equal(calls[0].event.recurrence[0], 'RRULE:FREQ=WEEKLY;COUNT=4');
  assert.equal((await bridge.request('/v1/calendar/events/fixture', { method: 'PATCH', token, body: draft, key: 'edit-missing-etag' })).status, 400);
  assert.equal((await bridge.request('/v1/calendar/events/fixture', { method: 'PATCH', token, body: { ...draft, etag: '"v1"' }, key: 'edit' })).status, 200);
  assert.equal((await bridge.request('/v1/calendar/events/fixture', { method: 'DELETE', token, body: { calendarId: 'primary', etag: '"v2"' }, key: 'delete' })).status, 200);
  assert.equal(calls.at(-1).etag, '"v2"');
  for (const date of ['bad','2026-99-99','2026-02-30']) assert.equal((await bridge.request('/v1/calendar/events', { method: 'POST', token, body: { ...draft, allDay: true, start: date, end: '2026-11-04' }, key: `bad-${date}` })).status, 400);
});

test('Drive upload routes require explicit write scope and enforce chunk bounds', async t => {
  let calls = 0;
  const bridge = await startBridge({ drive: { beginUpload: async p => { calls++; return { id: '00000000-0000-0000-0000-000000000000', deviceId: p.deviceId }; }, uploadChunk: async p => ({ size: p.body.length }) } });
  t.after(() => bridge.close());
  const token = await bridge.token(['media:read']);
  const body = { name: 'test.pdf', mimeType: 'application/pdf', size: 10 };
  assert.equal((await bridge.request('/v1/drive/uploads', { method: 'POST', token, body, key: 'a' })).status, 403);
  const write = await bridge.token(['media:write']);
  assert.equal((await bridge.request('/v1/drive/uploads', { method: 'POST', token: write, body, key: 'b' })).status, 201);
  assert.equal((await bridge.request('/v1/drive/uploads', { method: 'POST', token: write, body, key: 'b' })).status, 201);
  assert.equal(calls, 1);
  assert.equal((await bridge.request('/v1/drive/uploads', { method: 'POST', token: write, body: 'not json', key: 'c' })).status, 400);
  // Phone chunks are raw bytes despite the client's generic JSON request API.
  const bytes = Buffer.from([0, 255, 10, 128]);
  const chunkURL = `${bridge.base}/v1/drive/uploads/00000000-0000-0000-0000-000000000000/chunks/0`;
  const headers = { authorization: `Bearer ${write}`, 'content-type': 'application/json', 'idempotency-key': 'raw-chunk' };
  const chunk = await fetch(chunkURL, { method: 'PUT', headers, body: bytes });
  assert.equal(chunk.status, 200); assert.equal((await chunk.json()).data.size, bytes.length);
  const retry = await fetch(chunkURL, { method: 'PUT', headers, body: bytes });
  assert.equal(retry.status, 200); assert.equal((await retry.json()).data.size, bytes.length);
  const oversized = await fetch(chunkURL, { method: 'PUT', headers: { ...headers, 'idempotency-key': 'oversized' }, body: Buffer.alloc(4 * 1024 * 1024 + 1) });
  assert.equal(oversized.status, 413); await oversized.arrayBuffer();

});

test('reminders use Google defaults, isolate instances, skip email and dedupe successful delivery', async () => {
  const now = Date.parse('2026-11-02T01:50:00Z'); const notices = [];
  const service = { calendars: async () => ({ items: [{ id: 'primary', selected: true, defaultReminders: [{ method: 'popup', minutes: 10 }, { method: 'email', minutes: 10 }] }] }),
    list: async () => ({ items: [{ id: 'e1', title: 'Fixture', start: '2026-11-02T02:00:00Z', reminders: { useDefault: true } }] }) };
  const reminders = createCalendarReminders({ service, now: () => now, notify: async notice => { notices.push(notice); return { delivered: true }; } });
  await reminders.tick(); await reminders.tick();
  assert.equal(notices.length, 1); assert.equal(notices[0].kind, 'calendar'); assert.match(notices[0].deepLink, /^laa:\/\/today\/events\/e1\?calendar=primary$/);
});

test('calendar save forwards etag, recurrence and attendee notification flag, remove never leaks body', async () => {
  const connection = mockConnection((url, options) => options.method === 'DELETE' ? new Response(null, { status: 204 }) : json({ id: 'one', etag: '"v2"', summary: 'Fixture', start: { dateTime: draft.start }, end: { dateTime: draft.end } }));
  const calendar = createGoogleCalendar({ connection });
  await calendar.save({ calendarId: 'primary', id: 'one', etag: '"v1"', event: { summary: 'Fixture', recurrence: ['RRULE:FREQ=DAILY'] } });
  assert.equal(connection.calls[0].options.headers['if-match'], '"v1"');
  assert.equal(connection.calls[0].url.searchParams.get('sendUpdates'), 'all');
  assert.equal(connection.calls[0].options.method, 'PATCH');
  assert.equal((await calendar.remove({ calendarId: 'primary', id: 'one', etag: '"v2"' })).deleted, true);
});


test('Drive reads manually follow only trusted Google redirects with a fixed hop limit', async () => {
  const visited = [];
  const connection = createGoogleConnection({ env: {}, readCredential: async () => credential, fetchImpl: async (url, options) => {
    const u = new URL(url); visited.push(u.hostname);
    assert.equal(options.redirect, 'manual');
    if (u.hostname === 'oauth2.googleapis.com') return json({ access_token: 'fixture-access' });
    if (u.hostname === 'www.googleapis.com') return new Response(null, { status: 302, headers: { location: 'https://drive.usercontent.google.com/download?id=fixture' } });
    assert.equal(options.headers.range, 'bytes=0-3');
    return new Response('abcd', { status: 206 });
  } });
  const opened = await createGoogleDrive({ connection }).open('file123', { range: 'bytes=0-3' });
  let bytes = ''; for await (const chunk of opened.stream) bytes += chunk;
  assert.equal(bytes, 'abcd'); assert.deepEqual(visited, ['oauth2.googleapis.com','www.googleapis.com','drive.usercontent.google.com']);
  for (const location of ['https://evil.example/content', 'http://drive.usercontent.google.com/a', 'https://drive.usercontent.google.com.evil.example/a', 'https://drive.usercontent.google.com@evil.example/a']) {
    const hosts = [];
    const denied = createGoogleConnection({ env: {}, readCredential: async () => credential, fetchImpl: async url => {
      const u = new URL(url); hosts.push(u.hostname);
      return u.hostname === 'oauth2.googleapis.com' ? json({ access_token: 'fixture-access' }) : new Response(null, { status: 302, headers: { location } });
    } });
    await assert.rejects(denied.request('https://www.googleapis.com/drive/v3/files/x?alt=media', {}, 'drive'), e => e.code === 'google_url_invalid');
    assert.equal(hosts.length, 2);
  }
  let reads = 0;
  const loop = createGoogleConnection({ env: {}, readCredential: async () => credential, fetchImpl: async url => new URL(url).hostname === 'oauth2.googleapis.com'
    ? json({ access_token: 'fixture-access' }) : (reads++, new Response(null, { status: 302, headers: { location: 'https://www.googleapis.com/loop' } })) });
  await assert.rejects(loop.request('https://www.googleapis.com/loop', {}, 'drive'), e => e.code === 'drive_invalid_response');
  assert.equal(reads, 4);
});

test('Drive errors preserve their area and 404/conflicts preserve nonretryable status without secrets in responses or logs', async t => {
  for (const status of [404,409,412]) {
    const connection = createGoogleConnection({ env: {}, readCredential: async () => credential, fetchImpl: async url => new URL(url).hostname === 'oauth2.googleapis.com'
      ? json({ access_token: 'fixture-access' }) : json({ error: 'fixture-secret' }, status) });
    await assert.rejects(connection.request('https://www.googleapis.com/drive/v3/files/file123', {}, 'drive'), e =>
      e.status === (status === 404 ? 404 : 409) && e.code === (status === 404 ? 'drive_not_found' : 'drive_conflict') && !e.retryable && !e.message.includes('fixture-secret'));
  }
  const logs = [];
  const connection = createGoogleConnection({ env: {}, readCredential: async () => credential, fetchImpl: async url => {
    if (new URL(url).hostname === 'oauth2.googleapis.com') return json({ access_token: 'fixture-access' });
    throw new Error('fixture-secret');
  } });
  const bridge = await startBridge({ drive: createGoogleDrive({ connection }), log: record => logs.push(record) }); t.after(() => bridge.close());
  const result = await bridge.request('/v1/drive/files', { token: await bridge.token(['media:read']) });
  assert.equal(result.status, 503); assert.equal(result.body.error.code, 'drive_unavailable');
  for (const secret of ['fixture-secret','fixture-refresh','fixture-access']) assert.equal(JSON.stringify({ result, logs }).includes(secret), false);
  const missing = createGoogleConnection({ env: {}, readCredential: async () => { throw new Error('fixture-secret'); } });
  await assert.rejects(missing.request('https://www.googleapis.com/drive/v3/files', {}, 'drive'), e => e.code === 'drive_not_configured' && !e.message.includes('fixture-secret'));
});

test('upload recovery queries Google after lost partial and final acknowledgements; hostile locations and mismatched ACKs are rejected', async () => {
  const size = 256 * 1024 + 4; let received = 0; let complete = false; let queries = 0;
  const connection = mockConnection((url, options) => {
    if (options.method === 'POST') return new Response(null, { headers: { location: 'https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture' } });
    if (options.headers['content-range'] === `bytes */${size}`) {
      queries++; assert.equal(options.body.length, 0);
      return complete ? json(file) : new Response(null, { status: 308, headers: received ? { range: `bytes=0-${received-1}` } : {} });
    }
    received += options.body.length; complete = received === size;
    throw new Error('response lost');
  });
  const drive = createGoogleDrive({ connection });
  const upload = await drive.beginUpload({ name: 'Test.pdf', mimeType: file.mimeType, size, deviceId: 'owner' });
  await assert.rejects(drive.uploadChunk({ id: upload.id, deviceId: 'owner', offset: 0, body: Buffer.alloc(256 * 1024) }));
  assert.equal((await drive.uploadStatus({ id: upload.id, deviceId: 'owner' })).offset, 256 * 1024);
  await assert.rejects(drive.uploadChunk({ id: upload.id, deviceId: 'owner', offset: received, body: Buffer.alloc(4) }));
  assert.equal((await drive.uploadStatus({ id: upload.id, deviceId: 'owner' })).completed, true);
  assert.equal((await drive.uploadStatus({ id: upload.id, deviceId: 'owner' })).completed, true);
  assert.equal(queries, 2);
  for (const location of ['https://evil.example/upload/drive/files', 'https://user@www.googleapis.com/upload/drive/files', 'http://www.googleapis.com/upload/drive/files']) {
    const denied = createGoogleDrive({ connection: mockConnection(() => new Response(null, { headers: { location } })) });
    await assert.rejects(denied.beginUpload({ name: 'Test.pdf', mimeType: file.mimeType, size, deviceId: 'owner' }), e => e.code === 'drive_invalid_response');
  }
  const mismatch = createGoogleDrive({ connection: mockConnection((url, options) => options.method === 'POST'
    ? new Response(null, { headers: { location: 'https://www.googleapis.com/upload/drive/v3/files?upload_id=mismatch' } })
    : new Response(null, { status: 308, headers: { range: 'bytes=0-3' } })) });
  const other = await mismatch.beginUpload({ name: 'Test.pdf', mimeType: file.mimeType, size, deviceId: 'owner' });
  await assert.rejects(mismatch.uploadChunk({ id: other.id, deviceId: 'owner', offset: 0, body: Buffer.alloc(256 * 1024) }), e => e.code === 'drive_invalid_response');
});

test('calendar excludes only invalid events, reports their count, and safely accepts encoded imported IDs', async t => {
  const good = { id: 'imported@example.com', summary: 'Imported', start: { dateTime: draft.start }, end: { dateTime: draft.end } };
  const service = createGoogleCalendar({ connection: mockConnection(() => json({ items: [good, null, { id: 'bad', start: { date: '2026-02-30' }, end: { date: '2026-03-04' } }] })) });
  const result = await service.list({ start: draft.start, end: draft.end });
  assert.equal(result.items.length, 1); assert.equal(result.skippedCount, 2);
  const calls = [];
  const bridge = await startBridge({ calendar: { service: { get: async p => (calls.push(p), p), save: async p => (calls.push(p), p), remove: async p => (calls.push(p), { deleted: true }) } } }); t.after(() => bridge.close());
  const token = await bridge.token(['calendar:read','calendar:write']);
  const path = '/v1/calendar/events/imported%40example.com%23part%2B_';
  assert.equal((await bridge.request(path + '?calendarId=work%2Bteam%40example.com%23_' , { token })).status, 200);
  assert.equal(calls[0].id, 'imported@example.com#part+_'); assert.equal(calls[0].calendarId, 'work+team@example.com#_');
  for (const method of ['PATCH','DELETE']) assert.equal((await bridge.request(path, { token, method, body: { ...draft, etag: 'version' }, key: method })).status, 200);
  assert.equal((await bridge.request('/v1/calendar/events/a%2Fb?calendarId=primary', { token })).status, 400);
  assert.equal(calls.length, 3);
});

test('reminders catch up after upstream failure and restart without delivering twice', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'google-reminders-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, 'reminders.json'); const notices = []; let fail = true;
  const time = Date.parse('2026-11-02T03:00:00Z');
  const service = { calendars: async () => ({ items: [{ id: 'primary', selected: true, timeZone: 'Asia/Tokyo', defaultReminders: [{ method: 'popup', minutes: 0 }] }] }),
    list: async () => { if (fail) throw new Error('temporary upstream error'); return { items: [{ id: 'late', title: 'Late', start: '2026-11-02', allDay: true, reminders: { useDefault: true } }] }; } };
  const options = { service, file, now: () => time, notify: async notice => { notices.push(notice); return { delivered: true }; } };
  const reminders = createCalendarReminders(options);
  await assert.rejects(reminders.tick()); fail = false; await reminders.tick();
  await createCalendarReminders(options).tick(); assert.equal(notices.length, 1);
  assert.match(notices[0].deepLink, /calendar=primary/);
});
