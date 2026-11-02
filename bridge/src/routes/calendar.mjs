import { badRequest } from '../errors.mjs';
import { createGoogleCalendar } from '../calendar/google.mjs';

export function calendarRoutes({ service = createGoogleCalendar() } = {}) {
  return [{ method: 'GET', path: '/v1/calendar/events', auth: true, scope: 'calendar:read', handler: async ({ req }) => {
    const url = new URL(req.url, 'http://localhost');
    const start = url.searchParams.get('start');
    const end = url.searchParams.get('end');
    const instant = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;
    if (!start || !end || !instant.test(start) || !instant.test(end)
      || !Number.isFinite(Date.parse(start)) || !Number.isFinite(Date.parse(end))
      || Date.parse(end) <= Date.parse(start) || Date.parse(end) - Date.parse(start) > 8 * 86400000) {
      throw badRequest('calendar_range_invalid', 'A period of up to eight days is required');
    }
    return { status: 200, data: await service.list({ start, end }) };
  } }];
}
