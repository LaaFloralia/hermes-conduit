import { atMost, createDuetClient, duetOrigin, MAX_NOTE } from '../duet/client.mjs';
import { createDuetService } from '../duet/service.mjs';
import { badRequest, markBeforeWrite } from '../errors.mjs';
import { parseObjectBody } from './state-file.mjs';

export function duetRoutes({ dir, now, live, registerCleanup }) {
  // A lab lane or unit-test process never reads production credentials nor
  // starts network/notifier I/O. Live is set only by the Bridge entry point.
  const enabled = live && process.env.NODE_TEST_CONTEXT === undefined;
  const url = enabled && process.env.LAA_DUET_CONNECTOR_URL;
  const token = enabled && process.env.LAA_DUET_PULL_TOKEN;
  const origin = url && duetOrigin(url);
  const client = origin && /^[A-Za-z0-9_-]{43}$/.test(token ?? '') ? createDuetClient({ origin, token }) : null;
  const service = createDuetService({ dir, now, client, idleError: url && token && !client ? 'invalid_configuration' : 'not_configured',
    notify: async (item) => (await import('../duet/notify.mjs')).notifyDuetItem(item) });
  if (client) registerCleanup?.(service.start());

  return [
    { method: 'GET', path: '/v1/duet/items', auth: true, scope: 'sessions:read', handler: ({ req }) => {
      const limit = new URL(req.url, 'http://localhost').searchParams.get('limit') ?? '50';
      if (!/^[1-9][0-9]{0,2}$/.test(limit) || Number(limit) > 200) throw badRequest('duet_limit_invalid', 'limit must be 1–200.');
      return { status: 200, data: service.listItems(Number(limit)) };
    } },
    { method: 'GET', path: '/v1/duet/notes', auth: true, scope: 'sessions:read', handler: () => ({ status: 200, data: service.listNotes() }) },
    { method: 'POST', path: '/v1/duet/notes', auth: true, scope: 'sessions:write', idempotent: true, bodyLimit: 25_000,
      releaseOnError: (error) => error.writeStarted === false,
      handler: async ({ rawBody }) => {
        let data;
        try {
          data = parseObjectBody(rawBody);
          if (Object.keys(data).length !== 1 || !atMost(data.text, MAX_NOTE)) throw badRequest('duet_note_invalid', 'text must be a string of at most 2000 characters.');
        } catch (error) { throw markBeforeWrite(error); }
        return { status: 201, data: await service.postNote(data.text) };
      } },
  ];
}
