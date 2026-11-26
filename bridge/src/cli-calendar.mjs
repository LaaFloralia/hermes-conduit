// Read-only Calendar for agents on the Mac (owner brief, staff skills). It reuses the
// Bridge's Google connection in-process: no HTTP service, no device token, no writes.
import { BridgeError } from './errors.mjs';
import { createGoogleCalendar } from './calendar/google.mjs';

export const CALENDAR_USAGE = `laa-bridge calendar — 予定の読取り（書込みなし）

  calendar events [--from YYYY-MM-DD|today] [--days N] [--json]
                 既定は今日から2日（Asia/Tokyo）。N は1〜42。表示中の全カレンダー
  calendar calendars [--json]

予定の作成・変更・削除はアプリ（Bridge の calendar:write）だけ。取得できない時は終了コード6で、
空の予定にしません。Exit codes: 0 success, 2 usage, 6 calendar unavailable, 1 unexpected.
`;

const DAY = 86_400_000;
const JST = 9 * 3_600_000;

class UsageError extends Error {}

export function calendarRange({ from = 'today', days = '2' } = {}, now = Date.now()) {
  const n = Number(days);
  if (!Number.isInteger(n) || n < 1 || n > 42) throw new UsageError('--days must be an integer from 1 to 42');
  let startDay;
  if (from === 'today') startDay = new Date(now + JST).toISOString().slice(0, 10);
  else if (/^\d{4}-\d{2}-\d{2}$/.test(from) && new Date(`${from}T00:00:00Z`).toISOString().slice(0, 10) === from) startDay = from;
  else throw new UsageError('--from must be YYYY-MM-DD or today');
  const start = Date.parse(`${startDay}T00:00:00+09:00`);
  return { start: new Date(start).toISOString(), end: new Date(start + n * DAY).toISOString() };
}

// Attendee e-mail addresses stay out of the output; callers decide "external" from domains.
export function summarize(items) {
  return items.map((e) => ({ id: e.id, calendarId: e.calendarId, title: e.title, start: e.start, end: e.end, allDay: e.allDay,
    location: e.location, meetingLink: e.meetingLink, attendeeCount: e.attendees.length,
    attendeeDomains: [...new Set(e.attendees.map((a) => a.email.split('@')[1]).filter(Boolean))] }));
}

export async function calendarCommand(positional, flags, { service, now, out = process.stdout, err = process.stderr } = {}) {
  const sub = positional[0];
  const write = (value, text) => out.write(flags.json ? `${JSON.stringify(value)}\n` : text);
  try {
    if (positional.length !== 1 || !['events', 'calendars'].includes(sub)) throw new UsageError('use: calendar events|calendars');
    const cal = service ?? createGoogleCalendar();
    const calendars = (await cal.calendars()).items.filter((c) => c.selected);
    if (sub === 'calendars') {
      write({ ok: true, items: calendars.map(({ id, title, timeZone, writable }) => ({ id, title, timeZone, writable })) },
        calendars.map((c) => `${c.title}\t${c.id}`).join('\n') + '\n');
      return 0;
    }
    const range = calendarRange({ from: flags.from ?? 'today', days: flags.days ?? '2' }, now ?? Date.now());
    const result = await cal.list({ ...range, calendarIds: calendars.map((c) => c.id) });
    const items = summarize(result.items);
    write({ ok: true, source: result.source, start: range.start, end: range.end, calendars: calendars.length,
      skipped: result.skippedCount, items },
      items.length ? items.map((e) => `${e.start}\t${e.title}`).join('\n') + '\n' : '予定なし（取得成功）\n');
    return 0;
  } catch (error) {
    if (error instanceof UsageError) { err.write(`laa-bridge: ${error.message}\n`); return 2; }
    const code = error instanceof BridgeError ? error.code : 'calendar_unexpected';
    if (flags.json) out.write(`${JSON.stringify({ ok: false, error: { code } })}\n`);
    err.write(`laa-bridge: calendar unavailable (${code})\n`);
    return error instanceof BridgeError ? 6 : 1;
  }
}
