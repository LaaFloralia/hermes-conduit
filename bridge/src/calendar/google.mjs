import { BridgeError } from '../errors.mjs';
import { createGoogleConnection, googleConnection } from '../google/connection.mjs';
export { DEFAULT_CREDENTIAL_HELPER, readCredentialViaHelper } from '../google/connection.mjs';

const failure = (code = 'calendar_invalid_response') => new BridgeError(503, code, 'Google Calendar returned an invalid response');
const eventFields = 'id,etag,status,summary,start,end,location,description,htmlLink,hangoutLink,conferenceData,attendees,attachments,recurrence,recurringEventId,originalStartTime,reminders,organizer';
export function calendarEvent(event, calendarId) {
  if (!event || typeof event !== 'object') throw failure();
  const allDay = typeof event.start?.date === 'string';
  const start = allDay ? event.start.date : event.start?.dateTime;
  const end = allDay ? event.end?.date : event.end?.dateTime;
  if (!event.id || typeof start !== 'string' || typeof end !== 'string'
    || !Number.isFinite(Date.parse(start)) || !Number.isFinite(Date.parse(end)) || Date.parse(end) <= Date.parse(start)
    || (allDay && (!/^\d{4}-\d{2}-\d{2}$/.test(start) || !/^\d{4}-\d{2}-\d{2}$/.test(end)))) throw failure();
  return { id: event.id, calendarId, title: event.summary?.trim() || '（タイトルなし）', start, end, allDay,
    location: event.location ?? null, description: event.description ?? null, etag: event.etag ?? null,
    meetingLink: event.hangoutLink ?? event.conferenceData?.entryPoints?.find(x => x.entryPointType === 'video')?.uri ?? null,
    attendees: (event.attendees ?? []).map(x => ({ email: x.email, name: x.displayName ?? null, response: x.responseStatus ?? null })),
    attachments: (event.attachments ?? []).map(x => ({ title: x.title ?? '添付', url: x.fileUrl })),
    recurrence: event.recurrence ?? [], recurringEventId: event.recurringEventId ?? null,
    timeZone: event.start.timeZone ?? null, reminders: event.reminders ?? { useDefault: true } };
}
export function createGoogleCalendar(options = {}) {
  const connection = options.connection ?? (Object.keys(options).length ? createGoogleConnection(options) : googleConnection);
  const { request, json } = connection;
  async function pages(path, parameters) {
    const items = []; let pageToken;
    for (let page = 0; page < 40; page++) {
      const url = new URL(`https://www.googleapis.com/calendar/v3/${path}`);
      for (const [key, value] of Object.entries(parameters)) url.searchParams.set(key, value);
      if (pageToken) url.searchParams.set('pageToken', pageToken);
      const data = await json(await request(url));
      if (!Array.isArray(data?.items)) throw failure();
      items.push(...data.items);
      pageToken = data.nextPageToken;
      if (!pageToken) return items;
      if (typeof pageToken !== 'string') throw failure();
    }
    throw failure('calendar_too_many_events');
  }
  return {
    async calendars() {
      const items = await pages('users/me/calendarList', { maxResults: '250', showHidden: 'false' });
      return { items: items.map(c => ({ id: c.id, title: c.summaryOverride ?? c.summary ?? c.id,
        color: c.backgroundColor ?? '#176B66', timeZone: c.timeZone, selected: c.selected !== false,
        writable: ['owner', 'writer'].includes(c.accessRole), defaultReminders: c.defaultReminders ?? [] })) };
    },
    async list({ start, end, calendarIds }) {
      const token = await connection.accessToken();
      const ids = calendarIds?.length ? calendarIds : [token.calendarId];
      const groups = await Promise.all(ids.map(async id => {
        const items = await pages(`calendars/${encodeURIComponent(id)}/events`, { timeMin: start, timeMax: end,
          singleEvents: 'true', orderBy: 'startTime', showDeleted: 'false', maxResults: '250', fields: `items(${eventFields}),nextPageToken` });
        return items.filter(e => e?.status !== 'cancelled').map(e => calendarEvent(e, id));
      }));
      return { items: groups.flat().sort((a,b) => a.start.localeCompare(b.start)), source: 'google', start, end };
    },
    async get({ calendarId, id }) {
      return calendarEvent(await json(await request(`https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(id)}`)), calendarId);
    },
    async save({ calendarId, id, event, etag, key }) {
      const url = new URL(`https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events${id ? `/${encodeURIComponent(id)}` : ''}`);
      // Attendee notifications are part of the user's explicit save in the editor.
      url.searchParams.set('sendUpdates', 'all'); url.searchParams.set('supportsAttachments', 'true');
      const response = await request(url, { method: id ? 'PATCH' : 'POST',
        headers: { 'content-type': 'application/json', ...(etag ? { 'if-match': etag } : {}) },
        body: JSON.stringify({ ...event, ...(!id && key ? { id: key } : {}) }) });
      return calendarEvent(await json(response), calendarId);
    },
    async remove({ calendarId, id, etag }) {
      const url = new URL(`https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(id)}`);
      url.searchParams.set('sendUpdates', 'all');
      await request(url, { method: 'DELETE', headers: etag ? { 'if-match': etag } : {} });
      return { deleted: true, id };
    },
  };
}
