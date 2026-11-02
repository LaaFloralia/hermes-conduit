import { createHash } from 'node:crypto';
import { badRequest } from '../errors.mjs';
import { createGoogleCalendar } from '../calendar/google.mjs';

function payload(raw) {
  let p; try { p = JSON.parse(raw); } catch { throw badRequest('payload_invalid', 'Invalid calendar payload'); }
  if (!p || typeof p !== 'object' || Array.isArray(p)) throw badRequest('payload_invalid', 'Invalid calendar payload');
  return p;
}
function calendarId(value) {
  if (typeof value !== 'string' || !value.trim() || value.length > 1024 || /[\x00-\x1f]/.test(value)) throw badRequest('calendar_id_invalid', 'A calendar ID is required');
  return value;
}
function eventId(value) {
  let id; try { id = decodeURIComponent(value); } catch { }
  if (typeof id !== 'string' || !/^[A-Za-z0-9_.@+-]{1,1024}$/.test(id)) throw badRequest('event_id_invalid', 'Invalid event ID');
  return id;
}
const instant = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;
export function validateEvent(p) {
  if (typeof p.title !== 'string' || !p.title.trim() || p.title.length > 1024) throw badRequest('event_title_invalid', 'A title is required');
  const date = value => typeof value === 'string' && Number.isFinite(Date.parse(value)) && (p.allDay === true ? /^\d{4}-\d{2}-\d{2}$/.test(value)
    && new Date(value).toISOString().slice(0,10) === value : instant.test(value)) && Number.isFinite(Date.parse(value));
  if (!date(p.start) || !date(p.end) || Date.parse(p.end) <= Date.parse(p.start)) throw badRequest('event_time_invalid', 'Valid start and end are required');
  if (p.timeZone !== undefined && p.timeZone !== null) { try { new Intl.DateTimeFormat('en', { timeZone: p.timeZone }); } catch { throw badRequest('event_timezone_invalid', 'Invalid timezone'); } }
  const event = { summary: p.title.trim(), start: p.allDay ? { date: p.start } : { dateTime: p.start, timeZone: p.timeZone ?? 'Asia/Tokyo' },
    end: p.allDay ? { date: p.end } : { dateTime: p.end, timeZone: p.timeZone ?? 'Asia/Tokyo' } };
  for (const [input, output, limit] of [['location','location',4096], ['description','description',32000]]) {
    if (p[input] !== undefined) {
      if (typeof p[input] !== 'string' || p[input].length > limit) throw badRequest('event_text_invalid', 'Invalid event text');
      event[output] = p[input];
    }
  }
  if (p.recurrence !== undefined) {
    if (!Array.isArray(p.recurrence) || p.recurrence.length > 8 || p.recurrence.some(x => typeof x !== 'string' || x.length > 1024 || /[\r\n]/.test(x) || !/^(RRULE|RDATE|EXDATE):/.test(x))) throw badRequest('event_recurrence_invalid', 'Invalid recurrence');
    event.recurrence = p.recurrence;
  }
  if (p.attendees !== undefined) {
    if (!Array.isArray(p.attendees) || p.attendees.length > 100 || p.attendees.some(x => !x || typeof x.email !== 'string' || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(x.email))) throw badRequest('event_attendees_invalid', 'Invalid attendees');
    event.attendees = p.attendees.map(x => ({ email: x.email }));
  }
  if (p.reminderMinutes !== undefined) {
    if (p.reminderMinutes !== null && (!Number.isInteger(p.reminderMinutes) || p.reminderMinutes < 0 || p.reminderMinutes > 40320)) throw badRequest('event_reminders_invalid', 'Invalid reminder');
    event.reminders = p.reminderMinutes === null ? { useDefault: true } : { useDefault: false, overrides: [{ method: 'popup', minutes: p.reminderMinutes }] };
  }
  return event;
}
export function calendarRoutes({ service = createGoogleCalendar() } = {}) {
  return [
    { method: 'GET', path: '/v1/calendar/calendars', auth: true, scope: 'calendar:read', handler: async () => ({ status: 200, data: await service.calendars() }) },
    { method: 'GET', path: '/v1/calendar/events', auth: true, scope: 'calendar:read', handler: async ({ req }) => {
      const url = new URL(req.url, 'http://localhost');
      const start = url.searchParams.get('start'); const end = url.searchParams.get('end');
      if (!start || !end || !instant.test(start) || !instant.test(end) || !Number.isFinite(Date.parse(start)) || !Number.isFinite(Date.parse(end))
        || Date.parse(end) <= Date.parse(start) || Date.parse(end) - Date.parse(start) > 42 * 86400000 + 3600000) throw badRequest('calendar_range_invalid', 'A period of up to 42 days is required');
      const ids = url.searchParams.getAll('calendarId');
      if (ids.length > 20) throw badRequest('calendar_ids_invalid', 'At most 20 calendars');
      return { status: 200, data: await service.list({ start, end, ...(ids.length ? { calendarIds: ids.map(calendarId) } : {}) }) };
    } },
    { method: 'POST', path: '/v1/calendar/events', auth: true, scope: 'calendar:write', idempotent: true, handler: async ({ req, rawBody, device }) => {
      const p = payload(rawBody);
      const key = createHash('sha256').update(`${device.id}:${req.headers['idempotency-key']}`).digest('hex');
      return { status: 201, data: await service.save({ calendarId: calendarId(p.calendarId), event: validateEvent(p), key }) };
    } },
    { method: 'GET', pattern: /^\/v1\/calendar\/events\/([A-Za-z0-9_.@+%\-]{1,3072})$/, auth: true, scope: 'calendar:read', handler: async ({ req, params }) => ({ status: 200,
      data: await service.get({ calendarId: calendarId(new URL(req.url, 'http://localhost').searchParams.get('calendarId')), id: eventId(params[0]) }) }) },
    ...['PATCH','DELETE'].map(method => ({ method, pattern: /^\/v1\/calendar\/events\/([A-Za-z0-9_.@+%\-]{1,3072})$/, auth: true, scope: 'calendar:write', idempotent: true,
      handler: async ({ rawBody, params }) => {
        const p = payload(rawBody);
        if (typeof p.etag !== 'string' || !p.etag || p.etag.length > 256 || /[\r\n]/.test(p.etag)) throw badRequest('event_etag_required', 'Reload the event before editing');
        const target = { calendarId: calendarId(p.calendarId), id: eventId(params[0]), etag: p.etag };
        return { status: 200, data: method === 'DELETE' ? await service.remove(target) : await service.save({ ...target, event: validateEvent(p) }) };
      } })),
  ];
}
