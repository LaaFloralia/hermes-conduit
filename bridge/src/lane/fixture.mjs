import { createServer } from 'node:http';
import { LANE_HEADER, laneEnabled } from './guard.mjs';

export function laneFixture(handler) {
  if (!laneEnabled()) return handler;
  const id = process.env.LAA_LANE_ID;
  if (!/^[A-Za-z0-9_-]{1,96}$/.test(id)) throw new Error('invalid LAA_LANE_ID');
  return (req, res) => {
    res.setHeader(LANE_HEADER, id);
    if (req.headers[LANE_HEADER] !== id) {
      res.writeHead(421, { 'content-type': 'application/json', connection: 'close' });
      res.end(JSON.stringify({ error: { code: 'lane_mismatch', message: 'request belongs to a different lane', retryable: false } }));
      return;
    }
    if (req.method === 'GET' && req.url === '/v1/health') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ data: { lane: id }, requestId: 'ui-fixture' }));
      return;
    }
    return handler(req, res);
  };
}

export function createLaneFixtureServer(handler) {
  const wrapped = laneFixture(handler);
  const server = createServer(wrapped);
  if (laneEnabled()) {
    server.on('checkContinue', (req, res) => {
      if (req.headers[LANE_HEADER] === process.env.LAA_LANE_ID) res.writeContinue();
      wrapped(req, res);
    });
  }
  return server;
}

export function reportFixturePort(name, port) {
  if (!laneEnabled()) return;
  if (process.send) process.send({ fixture: name, port });
  else process.stdout.write(`${JSON.stringify({ fixture: name, port })}\n`);
}

export function listenLaneFixture(server, name, legacyPort, ready) {
  return server.listen(laneEnabled() ? 0 : legacyPort, '127.0.0.1', () => {
    reportFixturePort(name, server.address().port);
    ready?.();
  });
}
