import assert from 'node:assert/strict';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { localWorker } from './local-worker.mjs';

const modernVersion = '2026-07-28';
const accept = 'application/json, text/event-stream';
const json = (body) => ({ method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
const consent = (handle, cookie, origin, access) => ({
  method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: cookie, Origin: origin, 'X-Duet-Fixture-Access': access },
  body: new URLSearchParams({ handle }), redirect: 'manual',
});

export async function registration(origin) {
  const redirect = `${origin}/callback`;
  const registrationResponse = await fetch(`${origin}/register`, json({
    client_name: 'Fixture MCP client', redirect_uris: [redirect], token_endpoint_auth_method: 'none',
    response_types: ['code'], grant_types: ['authorization_code', 'refresh_token'],
  }));
  assert.equal(registrationResponse.status, 201, await registrationResponse.clone().text());
  const { client_id } = await registrationResponse.json();
  const verifier = randomBytes(32).toString('base64url');
  const state = randomUUID();
  const query = new URLSearchParams({ response_type: 'code', client_id, redirect_uri: redirect, state,
    scope: 'hortensia', resource: `${origin}/mcp`, code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256' });
  const token = (body) => fetch(`${origin}/token`, { method: 'POST', body: new URLSearchParams({ client_id, resource: `${origin}/mcp`, ...body }) });
  return { url: `${origin}/authorize?${query}`, redirect, verifier, state, token };
}

export async function oauthClient(fixture, { verifyFlow = false } = {}) {
  const { origin, access } = fixture;
  const { url, redirect, verifier, state, token } = await registration(origin);
  const grant = await fetch(url, { headers: { 'X-Duet-Fixture-Access': access }, redirect: 'manual' });
  assert.equal(grant.status, 200, await grant.clone().text());
  const cookie = grant.headers.getSetCookie().map((value) => value.split(';')[0]).join('; ');
  const page = await grant.text();
  const handle = /name="handle" value="([A-Za-z0-9_-]+)"/.exec(page)?.[1];
  assert.ok(handle && cookie, 'consent page must issue a bound handle');
  if (verifyFlow) {
    const rejected = await fetch(`${origin}/authorize`, consent(handle, '', origin, access));
    assert.equal(rejected.status, 400);
  }
  const authorized = await fetch(`${origin}/authorize`, consent(handle, cookie, origin, access));
  assert.equal(authorized.status, 303, await authorized.clone().text());
  const callback = new URL(authorized.headers.get('location'));
  assert.equal(`${callback.origin}${callback.pathname}`, redirect);
  assert.equal(callback.searchParams.get('state'), state);
  const code = callback.searchParams.get('code');
  assert.ok(code);
  const exchange = (code_verifier) => token({ grant_type: 'authorization_code', redirect_uri: redirect, code, code_verifier });
  if (verifyFlow) assert.equal((await exchange(randomBytes(32).toString('base64url'))).status, 400);
  const exchangeResponse = await exchange(verifier);
  assert.equal(exchangeResponse.status, 200, await exchangeResponse.clone().text());
  const tokens = await exchangeResponse.json();
  assert.equal(tokens.expires_in, 900);
  assert.ok(tokens.access_token && tokens.refresh_token);
  return { ...tokens, refresh: () => token({ grant_type: 'refresh_token', refresh_token: tokens.refresh_token }), replayCode: () => exchange(verifier) };
}

export function clients(fixture, accessToken) {
  let id = 0;
  return {
    rpc(method, params = {}, { modern = true, headers: other, notification = false } = {}) {
      const request = json({ jsonrpc: '2.0', ...(notification ? {} : { id: ++id }), method, params: modern ? { ...params, _meta: {
        'io.modelcontextprotocol/protocolVersion': modernVersion,
        'io.modelcontextprotocol/clientCapabilities': {},
      } } : params });
      const headers = { ...request.headers, Accept: accept, Authorization: `Bearer ${accessToken}` };
      if (modern) {
        headers['MCP-Protocol-Version'] = modernVersion;
        headers['Mcp-Method'] = method;
        if (method === 'tools/call') headers['Mcp-Name'] = params.name;
      }
      return fetch(`${fixture.origin}/mcp`, { ...request, headers: { ...headers, ...other } });
    },
    mac(path, payload) {
      const request = payload === undefined ? {} : json(payload);
      return fetch(`${fixture.origin}${path}`, { ...request, headers: { ...request.headers, Authorization: `Bearer ${fixture.pullToken}` } });
    },
  };
}

async function run() {
  const fixture = await localWorker();
  try {
    const { access_token, refresh, replayCode } = await oauthClient(fixture, { verifyFlow: true });
    const { rpc, mac } = clients(fixture, access_token);
    const list = await (await rpc('tools/list')).json();
    assert.deepEqual(list.result.tools.map((tool) => tool.name), ['hortensia_post', 'hortensia_notes_read']);
    const sample = { kind: 'brief', title: 'Fixture morning <brief>', body: 'Plain text, not **Markdown**.', link: 'https://example.invalid/brief' };
    const item = (await (await rpc('tools/call', { name: 'hortensia_post', arguments: sample })).json()).result.structuredContent;
    const pull = await (await mac('/pull?after=0')).json();
    assert.deepEqual(pull.items.map(({ createdAt, ...row }) => row), [{ ...item, ...sample }]);
    assert.equal((await mac('/ack', { through: item.id })).status, 200);
    assert.deepEqual((await (await mac('/pull?after=0')).json()).items, []);
    const note = { id: randomUUID(), text: 'Fixture note text: <script> is data.' };
    assert.equal((await mac('/notes', note)).status, 200);
    const name = 'hortensia_notes_read';
    const reply = await (await rpc('tools/call', { name })).json();
    assert.deepEqual(reply.result.structuredContent.notes.map(({ createdAt, ...row }) => row), [note]);
    assert.deepEqual((await (await mac('/notes/status')).json()).read, [note.id]);
    assert.equal((await refresh()).status, 200);
    assert.equal((await replayCode()).status, 400); // The provider revokes the grant on code replay.
    process.stdout.write('PASS: DCR → Access fixture → PKCE consent and token → tools/list → post → pull → ack → note → read → refresh\n');
  } finally {
    await fixture.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await run();
