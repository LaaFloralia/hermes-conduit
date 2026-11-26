import { BridgeError } from './errors.mjs';
import { laneClient } from './lane/client.mjs';
import { PRODUCTION_PORTS } from './lane/guard.mjs';
import { resolvePort } from './config.mjs';

export async function monetPost(path, body) {
  const token = process.env.LAA_BRIDGE_MONET_TOKEN;
  if (!/^[A-Za-z0-9_-]{43}$/.test(token ?? '')) {
    throw new BridgeError(403, 'monet_caller_required', 'trusted Monet runner credential is required');
  }
  const port = resolvePort();
  const test = process.env.NODE_TEST_CONTEXT;
  if (test && (!port || PRODUCTION_PORTS.includes(port))) throw new BridgeError(403, 'test_destination_denied', 'tests need a disposable Bridge port');
  const origin = `http://127.0.0.1:${port}`;
  const send = process.env.LAA_LANE_ID ? laneClient(origin, process.env.LAA_LANE_ID) : (p, options) => fetch(origin + p, options);
  const response = await send(path, { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(30_000),
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const result = await response.json();
  if (!response.ok) throw new BridgeError(response.status, result.error?.code ?? 'monet_operation_failed', result.error?.message ?? 'Monet operation failed');
  return result.data;
}
