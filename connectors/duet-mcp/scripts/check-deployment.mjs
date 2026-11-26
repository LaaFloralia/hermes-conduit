import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';

const cfg = JSON.parse(await readFile(new URL('../.deploy.local.json', import.meta.url), 'utf8'));
const deployed = new URL(cfg.origin);
assert.match(deployed.origin, /^https:\/\/laa-duet-connector\.[a-z0-9-]+\.workers\.dev$/);
assert.equal(deployed.href, `${deployed.origin}/`);

const get = (path, headers = {}) => fetch(new URL(path, deployed), { redirect: 'manual', signal: AbortSignal.timeout(15_000),
  headers: { 'User-Agent': 'Hortensia-Deployment-Check/1.0', ...headers } });
for (const path of ['/.well-known/oauth-protected-resource', '/.well-known/oauth-protected-resource/mcp']) {
  const response = await get(path);
  assert.equal(response.status, 200, path);
  const body = await response.json();
  assert.equal(body.resource, `${deployed.origin}/mcp`);
  assert.deepEqual(body.authorization_servers, [deployed.origin]);
  assert.deepEqual(body.scopes_supported, ['hortensia']);
}
const as = await get('/.well-known/oauth-authorization-server');
assert.equal(as.status, 200);
const metadata = await as.json();
assert.equal(metadata.authorization_endpoint, `${deployed.origin}/authorize`);
assert.equal(metadata.token_endpoint, `${deployed.origin}/token`);
assert.equal(metadata.registration_endpoint, `${deployed.origin}/register`);
const mcp = await get('/mcp');
assert.equal(mcp.status, 401);
assert.match(mcp.headers.get('www-authenticate'), /oauth-protected-resource\/mcp/);
assert.equal(mcp.headers.get('access-control-allow-origin'), null);
assert.equal((await get('/pull')).status, 401);
assert.equal((await get('/pull', { Authorization: `Bearer ${randomBytes(32).toString('base64url')}` })).status, 401);
const authorize = await get('/authorize');
assert.ok([302, 303, 307, 403].includes(authorize.status), '/authorize must require Access');
if (authorize.status !== 403) {
  const location = new URL(authorize.headers.get('location'));
  assert.ok([cfg.accessIssuer, 'https://accounts.google.com'].includes(location.origin));
}
console.log(`PASS: OAuth metadata 200; MCP and pull 401; Access unauthenticated ${authorize.status}`);
