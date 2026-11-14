import { createNotificationPreferences } from '../notify/preferences.mjs';
import { parseObjectBody } from './state-file.mjs';
export function notificationRoutes({ file, now }) {
  const preferences = createNotificationPreferences({ file, now });
  return [
    { method: 'GET', path: '/v1/notifications/preferences', auth: true, scope: 'sessions:read', handler: () => ({ status: 200, data: preferences.get() }) },
    { method: 'PUT', path: '/v1/notifications/preferences', auth: true, scope: 'sessions:write', idempotent: true, handler: ({ rawBody }) => ({ status: 200, data: preferences.update(parseObjectBody(rawBody)) }) },
  ];
}
