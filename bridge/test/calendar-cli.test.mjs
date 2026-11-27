import test from 'node:test';
import assert from 'node:assert/strict';
import { calendarCommand, calendarRange } from '../src/cli-calendar.mjs';
import { BridgeError } from '../src/errors.mjs';

const sink = () => { const s = { text: '', write: (t) => { s.text += t; } }; return s; };
const event = { id: 'e1', calendarId: 'c1', title: '打合せ', start: '2026-11-27T10:00:00+09:00', end: '2026-11-27T11:00:00+09:00', allDay: false,
  location: null, meetingLink: null, attendees: [{ email: 'owner@example.test' }, { email: 'x@client.example' }] };
const service = (fail) => ({
  calendars: async () => ({ items: [{ id: 'c1', title: 'A', selected: true }, { id: 'c2', title: 'B', selected: false }] }),
  list: async (args) => { if (fail) throw new BridgeError(503, 'calendar_not_configured', 'x'); service.args = args; return { items: [event], skippedCount: 0, source: 'google' }; },
});

test('range starts at Tokyo midnight and spans N days', () => {
  const r = calendarRange({ from: 'today', days: '2' }, Date.parse('2026-11-26T20:00:00Z'));
  assert.deepEqual(r, { start: '2026-11-26T15:00:00.000Z', end: '2026-11-28T15:00:00.000Z' });
});

test('events reads selected calendars only and hides attendee addresses', async () => {
  const out = sink(); const s = service(false); let args;
  s.list = async (a) => { args = a; return { items: [event], skippedCount: 0, source: 'google' }; };
  assert.equal(await calendarCommand(['events'], { json: true, days: '1', from: '2026-11-27' }, { service: s, out, err: sink() }), 0);
  const body = JSON.parse(out.text);
  assert.deepEqual(args.calendarIds, ['c1']);
  assert.deepEqual(body.items[0].attendeeDomains, ['example.test', 'client.example']);
  assert.ok(!out.text.includes('owner@example.test'));
  assert.ok(!out.text.includes('x@client.example'));
});

test('unavailable calendar is exit 6, never an empty list', async () => {
  const out = sink();
  assert.equal(await calendarCommand(['events'], { json: true }, { service: service(true), out, err: sink() }), 6);
  assert.deepEqual(JSON.parse(out.text), { ok: false, error: { code: 'calendar_not_configured' } });
});

test('bad input is a usage error', async () => {
  assert.equal(await calendarCommand(['events'], { days: '99' }, { service: service(false), out: sink(), err: sink() }), 2);
  assert.equal(await calendarCommand(['add'], {}, { service: service(false), out: sink(), err: sink() }), 2);
});
