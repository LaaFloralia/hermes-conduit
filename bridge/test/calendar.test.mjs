import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startBridge } from './helpers.mjs';
import {
  DEFAULT_CREDENTIAL_HELPER, createGoogleCalendar, readCredentialViaHelper,
} from '../src/calendar/google.mjs';

const range = { start: '2026-11-01T15:00:00Z', end: '2026-11-08T15:00:00Z' };
const path = `/v1/calendar/events?${new URLSearchParams(range)}`;
const env = { LAA_GOOGLE_CALENDAR_CLIENT_ID: 'fixture-client', LAA_GOOGLE_CALENDAR_CLIENT_SECRET: 'fixture-secret',
  LAA_GOOGLE_CALENDAR_REFRESH_TOKEN: 'fixture-refresh' };
const event = { id: 'one', summary: '予定', start: { dateTime: '2026-11-02T10:00:00+09:00' },
  end: { dateTime: '2026-11-02T11:00:00+09:00' }, location: '会議室', description: 'not returned' };
const response = (body, status = 200) => new Response(JSON.stringify(body), { status });
const credential = { client_id: 'fixture-client', client_secret: 'fixture-secret', refresh_token: 'fixture-refresh' };

function helperFixture(output, { error = null } = {}) {
  const calls = [];
  const execFileImpl = (file, args, options, callback) => {
    calls.push({ file, args, options });
    callback(error, output, 'fixture-stderr-secret');
  };
  return { calls, execFileImpl };
}

test('calendar requires read scope, validates range and rejects writes without write scope', async (t) => {
  const calls = [];
  const bridge = await startBridge({ calendar: { service: { list: async (query) => { calls.push(query); return { items: [] }; } } } });
  t.after(() => bridge.close());
  assert.equal((await bridge.request(path)).status, 401);
  assert.equal((await bridge.request(path, { token: await bridge.token() })).status, 403);
  const token = await bridge.token(['calendar:read']);
  assert.equal((await bridge.request(path, { token })).status, 200);
  assert.deepEqual(calls, [range]);
  for (const query of ['', '?start=bad&end=bad', '?start=2026-11-01T00:00:00Z&end=2027-01-01T00:00:00Z',
    '?start=2026-11-02T00:00:00Z&end=2026-11-01T00:00:00Z']) {
    assert.equal((await bridge.request(`/v1/calendar/events${query}`, { token })).status, 400);
  }
  assert.equal((await bridge.request(path, { token, method: 'POST', body: {} })).status, 403);
  assert.equal(calls.length, 1);
});

test('missing configuration is an explicit error, not an empty calendar', async (t) => {
  const bridge = await startBridge({
    calendar: { service: createGoogleCalendar({ env: {}, readCredential: async () => ({}) }) },
  });
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
  assert.equal(data.items[0].id, 'one');
  assert.equal(data.items[0].title, '予定');
  assert.equal(data.items[0].description, 'not returned');
  assert.equal(data.items[0].calendarId, 'primary');
  assert.equal(data.items[1].allDay, true);
  assert.equal(data.items[1].start, '2026-11-03');
  assert.equal(data.items[1].end, '2026-11-05');
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

test('credential helper runs without a shell or arguments and returns its JSON', async () => {
  const helper = helperFixture(JSON.stringify({ ...credential, calendar_id: 'team@example.com' }));
  const raw = await readCredentialViaHelper(undefined, { execFileImpl: helper.execFileImpl });
  assert.deepEqual(raw, { ...credential, calendar_id: 'team@example.com' });
  assert.equal(helper.calls.length, 1);
  assert.equal(helper.calls[0].file, DEFAULT_CREDENTIAL_HELPER);
  assert.deepEqual(helper.calls[0].args, []);
  assert.equal(helper.calls[0].options.shell, undefined);
  assert.ok(helper.calls[0].options.timeout > 0);
  assert.ok(helper.calls[0].options.maxBuffer > 0);
});

test('helper JSON drives a normal read and its calendar_id', async () => {
  const helper = helperFixture(JSON.stringify({ ...credential, calendar_id: 'team@example.com' }));
  const calls = [];
  const service = createGoogleCalendar({
    env: {},
    readCredential: () => readCredentialViaHelper(DEFAULT_CREDENTIAL_HELPER, { execFileImpl: helper.execFileImpl }),
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), options });
      return calls.length === 1
        ? response({ access_token: 'fixture-access', expires_in: 3600 })
        : response({ items: [event] });
    },
  });
  const data = await service.list(range);
  assert.equal(data.items.length, 1);
  assert.equal(calls[0].options.body.get('client_id'), credential.client_id);
  assert.ok(calls[1].url.includes(`/calendars/${encodeURIComponent('team@example.com')}/events`));
  assert.equal(JSON.stringify(data).includes('fixture-secret'), false);
});

test('helper failure, malformed JSON and missing fields are safe 503s, never empty', async () => {
  const secretError = Object.assign(new Error('fixture-secret in helper failure'), { stderr: 'fixture-secret' });
  const cases = [
    { error: secretError },
    { output: '' },
    { output: '{"client_id":"fixture-secret"' },
    { output: '[]' },
    { output: JSON.stringify({ client_id: 'fixture-client' }) },
    { output: JSON.stringify({ client_id: 'fixture-client', client_secret: 'fixture-secret' }) },
    { output: JSON.stringify({ ...credential, calendar_id: 7 }) },
  ];
  for (const item of cases) {
    const helper = helperFixture(item.output, { error: item.error });
    let fetched = false;
    const service = createGoogleCalendar({
      env: {},
      readCredential: () => readCredentialViaHelper(DEFAULT_CREDENTIAL_HELPER, { execFileImpl: helper.execFileImpl }),
      fetchImpl: async () => { fetched = true; return response({ access_token: 'fixture-access' }); },
    });
    await assert.rejects(service.list(range), (error) => {
      assert.equal(error.status, 503);
      assert.equal(error.code, 'calendar_not_configured');
      assert.equal(error.retryable, false);
      assert.equal(error.details, undefined);
      assert.equal(`${error.message}${error.stack}`.includes('fixture-secret'), false);
      return true;
    });
    assert.equal(fetched, false);
  }
});

test('explicit environment credentials override the helper', async () => {
  let helperCalls = 0;
  const calls = [];
  const service = createGoogleCalendar({
    env: { ...env, LAA_GOOGLE_CALENDAR_ID: 'env-calendar' },
    readCredential: async () => { helperCalls += 1; throw new Error('helper must not run'); },
    fetchImpl: async (url) => {
      calls.push(String(url));
      return calls.length === 1
        ? response({ access_token: 'fixture-access', expires_in: 3600 })
        : response({ items: [] });
    },
  });
  assert.deepEqual((await service.list(range)).items, []);
  assert.equal(helperCalls, 0);
  assert.ok(calls[1].includes(`/calendars/${encodeURIComponent('env-calendar')}/events`));
});

test('access tokens are reused until expiry and refreshed afterwards', async () => {
  let clock = 1_000_000;
  let authCalls = 0;
  const service = createGoogleCalendar({
    env,
    now: () => clock,
    fetchImpl: async (url) => {
      if (String(url).startsWith('https://oauth2.googleapis.com/token')) {
        authCalls += 1;
        return response({ access_token: `fixture-access-${authCalls}`, expires_in: 3600 });
      }
      return response({ items: [] });
    },
  });
  await service.list(range);
  await service.list(range);
  assert.equal(authCalls, 1);
  clock += 3600_000;
  await service.list(range);
  assert.equal(authCalls, 2);
  clock += 1_000;
  await service.list(range);
  assert.equal(authCalls, 2);
});

test('concurrent reads share one refresh', async () => {
  let authCalls = 0;
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const service = createGoogleCalendar({
    env,
    fetchImpl: async (url) => {
      if (String(url).startsWith('https://oauth2.googleapis.com/token')) {
        authCalls += 1;
        await gate;
        return response({ access_token: 'fixture-access', expires_in: 3600 });
      }
      return response({ items: [] });
    },
  });
  const first = service.list(range);
  const second = service.list(range);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(authCalls, 1);
  release();
  await Promise.all([first, second]);
  assert.equal(authCalls, 1);
});

test('an events 401 discards the used token and the next read refreshes it', async () => {
  let authCalls = 0;
  let eventCalls = 0;
  const service = createGoogleCalendar({
    env,
    fetchImpl: async (url) => {
      if (String(url).startsWith('https://oauth2.googleapis.com/token')) {
        authCalls += 1;
        return response({ access_token: `fixture-access-${authCalls}`, expires_in: 3600 });
      }
      eventCalls += 1;
      return eventCalls === 1
        ? response({ error: 'private upstream detail' }, 401)
        : response({ items: [] });
    },
  });
  await assert.rejects(service.list(range), (error) => error.code === 'calendar_auth_required');
  assert.deepEqual((await service.list(range)).items, []);
  assert.equal(authCalls, 2);
});

test('a late 401 does not discard a newer token cached by another read', async () => {
  let clock = 1_000_000;
  let authCalls = 0;
  let eventCalls = 0;
  let releaseFirst;
  const firstGate = new Promise((resolve) => { releaseFirst = resolve; });
  const service = createGoogleCalendar({
    env,
    now: () => clock,
    fetchImpl: async (url) => {
      if (String(url).startsWith('https://oauth2.googleapis.com/token')) {
        authCalls += 1;
        return response({ access_token: `fixture-access-${authCalls}`, expires_in: 3600 });
      }
      eventCalls += 1;
      if (eventCalls === 1) {
        await firstGate;
        return response({ error: 'private upstream detail' }, 401);
      }
      return response({ items: [] });
    },
  });
  const stale = service.list(range);
  while (eventCalls < 1) await new Promise((resolve) => setTimeout(resolve, 1));
  clock += 3600_000;
  await service.list(range);
  assert.equal(authCalls, 2);
  releaseFirst();
  await assert.rejects(stale, (error) => error.code === 'calendar_auth_required');
  await service.list(range);
  assert.equal(authCalls, 2);
});

test('a failed refresh releases the shared attempt for the next read', async () => {
  let authCalls = 0;
  const service = createGoogleCalendar({
    env,
    fetchImpl: async (url) => {
      if (String(url).startsWith('https://oauth2.googleapis.com/token')) {
        authCalls += 1;
        return authCalls === 1
          ? response({ error: 'private upstream detail' }, 503)
          : response({ access_token: 'fixture-access', expires_in: 3600 });
      }
      return response({ items: [] });
    },
  });
  await assert.rejects(service.list(range),
    (error) => error.code === 'calendar_unavailable' && error.retryable === true);
  assert.deepEqual((await service.list(range)).items, []);
  assert.equal(authCalls, 2);
});

test('a fixture helper script runs through the real execFile and hides stderr on failure', async (t) => {
  const dir = await mkdtemp(join(tmpdir(), 'laa-calendar-helper-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const good = join(dir, 'good.sh');
  await writeFile(good, `#!/bin/sh\nprintf '%s' '${JSON.stringify(credential)}'\n`);
  await chmod(good, 0o700);
  assert.deepEqual(await readCredentialViaHelper(good), credential);

  const bad = join(dir, 'bad.sh');
  await writeFile(bad, "#!/bin/sh\nprintf '%s' 'fixture-secret' >&2\nprintf '%s' '{\"client_id\":\"fixture-secret\"}'\nexit 1\n");
  await chmod(bad, 0o700);
  await assert.rejects(readCredentialViaHelper(bad), (error) => {
    assert.equal(error.status, 503);
    assert.equal(error.code, 'calendar_not_configured');
    assert.equal(`${error.message}${error.stack}`.includes('fixture-secret'), false);
    return true;
  });
});
