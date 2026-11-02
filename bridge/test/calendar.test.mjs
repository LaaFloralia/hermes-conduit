import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startBridge } from './helpers.mjs';
import { createGoogleCalendar } from '../src/calendar/google.mjs';

const range = { start: '2026-11-01T15:00:00Z', end: '2026-11-08T15:00:00Z' };
const path = `/v1/calendar/events?${new URLSearchParams(range)}`;
const env = { LAA_GOOGLE_CALENDAR_CLIENT_ID: 'fixture-client', LAA_GOOGLE_CALENDAR_CLIENT_SECRET: 'fixture-secret',
  LAA_GOOGLE_CALENDAR_REFRESH_TOKEN: 'fixture-refresh' };
const event = { id: 'one', summary: '予定', start: { dateTime: '2026-11-02T10:00:00+09:00' },
  end: { dateTime: '2026-11-02T11:00:00+09:00' }, location: '会議室', description: 'not returned' };
const response = (body, status = 200) => new Response(JSON.stringify(body), { status });

test('calendar requires its own scope, validates range and never accepts writes', async (t) => {
  const calls = [];
  const bridge = await startBridge({ calendar: { service: { list: async (query) => { calls.push(query); return { items: [] }; } } } });
  t.after(() => bridge.close());
  assert.equal((await bridge.request(path)).status, 401);
  assert.equal((await bridge.request(path, { token: await bridge.token() })).status, 403);
  const token = await bridge.token(['calendar:read']);
  assert.equal((await bridge.request(path, { token })).status, 200);
  assert.deepEqual(calls, [range]);
  for (const query of ['', '?start=bad&end=bad', '?start=2026-11-01T00:00:00Z&end=2026-12-01T00:00:00Z',
    '?start=2026-11-02T00:00:00Z&end=2026-11-01T00:00:00Z']) {
    assert.equal((await bridge.request(`/v1/calendar/events${query}`, { token })).status, 400);
  }
  assert.equal((await bridge.request(path, { token, method: 'POST', body: {} })).status, 405);
  assert.equal(calls.length, 1);
});

test('missing configuration is an explicit error, not an empty calendar', async (t) => {
  const bridge = await startBridge({ calendar: { service: createGoogleCalendar({ env: {} }) } });
  t.after(() => bridge.close());
  const result = await bridge.request(path, { token: await bridge.token(['calendar:read']) });
  assert.equal(result.status, 503);
  assert.equal(result.body.error.code, 'calendar_not_configured');
});

test('Google pagination expands recurrences and preserves date-only all-day boundaries', async () => {
  const calls = [];
  const service = createGoogleCalendar({ env, fetchImpl: async (url, options) => {
    calls.push({ url: String(url), options });
    if (calls.length === 1) return response({ access_token: 'fixture-access' });
    if (calls.length === 2) return response({ items: [event, { id: 'cancelled', status: 'cancelled' }], nextPageToken: 'next' });
    return response({ items: [{ id: 'all-day', start: { date: '2026-11-03' }, end: { date: '2026-11-05' } }] });
  } });
  const data = await service.list(range);
  assert.equal(data.items.length, 2);
  assert.deepEqual(data.items[0], { id: 'one', title: '予定', start: event.start.dateTime, end: event.end.dateTime, allDay: false, location: '会議室' });
  assert.deepEqual(data.items[1], { id: 'all-day', title: '（タイトルなし）', start: '2026-11-03', end: '2026-11-05', allDay: true, location: null });
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(calls[0].options.body.get('grant_type'), 'refresh_token');
  for (const call of calls.slice(1)) {
    assert.equal(call.options.method, 'GET');
    assert.equal(call.options.redirect, 'error');
    const url = new URL(call.url);
    assert.equal(url.hostname, 'www.googleapis.com');
    assert.equal(url.searchParams.get('singleEvents'), 'true');
    assert.equal(url.searchParams.get('orderBy'), 'startTime');
    assert.equal(url.searchParams.get('timeMin'), range.start);
    assert.equal(url.searchParams.get('timeMax'), range.end);
    assert.equal(url.searchParams.has('access_token'), false);
  }
  assert.equal(new URL(calls[2].url).searchParams.get('pageToken'), 'next');
  assert.equal(JSON.stringify(data).includes('fixture-secret'), false);
});

test('OAuth, permissions, missing calendar, rate limit and network errors stay sanitized', async () => {
  for (const [status, code] of [[401, 'calendar_auth_required'], [403, 'calendar_access_denied'], [404, 'calendar_not_found'], [429, 'calendar_unavailable']]) {
    let count = 0;
    const service = createGoogleCalendar({ env, fetchImpl: async () => ++count === 1
      ? response({ access_token: 'fixture-access' }) : response({ error: 'private upstream detail' }, status) });
    await assert.rejects(service.list(range), (error) => error.code === code && !error.message.includes('private'));
  }
  await assert.rejects(createGoogleCalendar({ env, fetchImpl: async () => response({ error: 'fixture-secret' }, 400) }).list(range),
    (error) => error.code === 'calendar_auth_required' && !error.message.includes('fixture-secret'));
  await assert.rejects(createGoogleCalendar({ env, fetchImpl: async () => { throw new Error('fixture-secret'); } }).list(range),
    (error) => error.code === 'calendar_unavailable' && !error.message.includes('fixture-secret'));
});

test('malformed and truncated upstream results never appear as a successful empty calendar', async () => {
  for (const result of [null, {}, { items: [null] }, { items: [{ id: 'bad', start: { date: 'wrong' } }] }, { items: [], nextPageToken: 'forever' }]) {
    let count = 0;
    const service = createGoogleCalendar({ env, fetchImpl: async () => ++count === 1 ? response({ access_token: 'fixture-access' }) : response(result) });
    await assert.rejects(service.list(range), (error) => ['calendar_invalid_response', 'calendar_too_many_events'].includes(error.code));
  }
});

test('valid empty Google calendar is successful', async () => {
  let count = 0;
  const service = createGoogleCalendar({ env, fetchImpl: async () => ++count === 1 ? response({ access_token: 'fixture-access' }) : response({ items: [] }) });
  assert.deepEqual((await service.list(range)).items, []);
});
