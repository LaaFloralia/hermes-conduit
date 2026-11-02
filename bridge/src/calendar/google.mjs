// Calendar is read-only. OAuth provisioning/consent is an operator step;
// credentials may only enter the running Bridge through its secret environment.
import { BridgeError } from '../errors.mjs';

const failure = (code, message, retryable = false) => new BridgeError(503, code, message, { retryable });

export function createGoogleCalendar({ env = process.env, fetchImpl = fetch } = {}) {
  return {
    async list({ start, end }) {
      const clientId = env.LAA_GOOGLE_CALENDAR_CLIENT_ID;
      const clientSecret = env.LAA_GOOGLE_CALENDAR_CLIENT_SECRET;
      const refreshToken = env.LAA_GOOGLE_CALENDAR_REFRESH_TOKEN;
      if (!clientId || !clientSecret || !refreshToken) {
        throw failure('calendar_not_configured', 'Google Calendar connection is not configured');
      }
      const signal = AbortSignal.timeout(12000);
      const request = async (url, options) => {
        try { return await fetchImpl(url, { ...options, signal, redirect: 'error' }); }
        catch { throw failure('calendar_unavailable', 'Google Calendar could not be reached', true); }
      };
      const json = async (response) => {
        try { return await response.json(); }
        catch { throw failure('calendar_invalid_response', 'Google Calendar returned an invalid response', true); }
      };
      const auth = await request('https://oauth2.googleapis.com/token', {
        method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ client_id: clientId, client_secret: clientSecret,
          refresh_token: refreshToken, grant_type: 'refresh_token' }),
      });
      if (!auth.ok) {
        throw failure(auth.status >= 500 || auth.status === 429 ? 'calendar_unavailable' : 'calendar_auth_required',
          'Google Calendar authorization could not be refreshed', auth.status >= 500 || auth.status === 429);
      }
      const token = await json(auth);
      if (typeof token?.access_token !== 'string' || !token.access_token) {
        throw failure('calendar_invalid_response', 'Google Calendar returned an invalid response');
      }
      const calendarId = env.LAA_GOOGLE_CALENDAR_ID || 'primary';
      const items = [];
      let pageToken;
      for (let page = 0; page < 10; page++) {
        const url = new URL(`https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events`);
        for (const [key, value] of Object.entries({ timeMin: start, timeMax: end, singleEvents: 'true',
          orderBy: 'startTime', showDeleted: 'false', maxResults: '250',
          fields: 'items(id,status,summary,start,end,location),nextPageToken' })) url.searchParams.set(key, value);
        if (pageToken) url.searchParams.set('pageToken', pageToken);
        const response = await request(url, { method: 'GET', headers: { authorization: `Bearer ${token.access_token}` } });
        if (!response.ok) {
          const code = response.status === 401 ? 'calendar_auth_required'
            : response.status === 403 ? 'calendar_access_denied'
              : response.status === 404 ? 'calendar_not_found' : 'calendar_unavailable';
          throw failure(code, 'Google Calendar events could not be read', response.status === 429 || response.status >= 500);
        }
        const data = await json(response);
        if (!Array.isArray(data?.items)) throw failure('calendar_invalid_response', 'Google Calendar returned an invalid response');
        for (const event of data.items) {
          if (!event || typeof event !== 'object') throw failure('calendar_invalid_response', 'Google Calendar returned an invalid event');
          if (event.status === 'cancelled') continue;
          const allDay = typeof event.start?.date === 'string';
          const eventStart = allDay ? event.start.date : event.start?.dateTime;
          const eventEnd = allDay ? event.end?.date : event.end?.dateTime;
          if (typeof event.id !== 'string' || !event.id || typeof eventStart !== 'string' || typeof eventEnd !== 'string'
            || !Number.isFinite(Date.parse(eventStart)) || !Number.isFinite(Date.parse(eventEnd))
            || Date.parse(eventEnd) <= Date.parse(eventStart)
            || (allDay && (!/^\d{4}-\d{2}-\d{2}$/.test(eventStart) || !/^\d{4}-\d{2}-\d{2}$/.test(eventEnd)))) {
            throw failure('calendar_invalid_response', 'Google Calendar returned an invalid event');
          }
          items.push({ id: event.id, title: typeof event.summary === 'string' && event.summary.trim() ? event.summary : '（タイトルなし）',
            start: eventStart, end: eventEnd, allDay, location: typeof event.location === 'string' ? event.location : null });
        }
        pageToken = data.nextPageToken;
        if (!pageToken) return { items, source: 'google', start, end };
        if (typeof pageToken !== 'string') throw failure('calendar_invalid_response', 'Google Calendar returned an invalid page');
      }
      throw failure('calendar_too_many_events', 'Too many Google Calendar events in this period');
    },
  };
}
