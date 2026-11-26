import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import test from 'node:test';
import { clients, oauthClient, registration } from '../scripts/fixture-client.mjs';
import { localWorker } from '../scripts/local-worker.mjs';
import { verifyAccessOwner } from '../src/access.mjs';
import { clientKey, cursor, validateNote, validatePost } from '../src/input.mjs';
import { prune } from '../src/store.mjs';

const sample = { kind: 'needs_owner', title: '<h1>Input?</h1>', body: '[text](javascript:ignored)', link: 'https://example.invalid' };
const call = (rpc, name, args) => rpc('tools/call', { name, arguments: args });

async function worker(t, authorize = false) {
  const fixture = await localWorker();
  t.after(() => fixture.close());
  const tokens = authorize ? await oauthClient(fixture) : {};
  return { ...fixture, ...clients(fixture, tokens.access_token), tokens };
}

test('field bounds count Unicode characters, reject extra fields, unsafe links and invalid cursors', () => {
  for (const patch of [{ kind: 'other' }, { title: 'x'.repeat(121) }, { body: 'x'.repeat(4001) }, { link: 'http://example.invalid' },
    { link: 'https://user@example.invalid' }, { link: 'https://example.invalid\\path' }, { link: 'https://example.invalid/' + 'x'.repeat(500) },
    { link: 'https://example.invalid/a b' }, { extra: true }]) assert.throws(() => validatePost({ ...sample, ...patch }));
  assert.deepEqual(validatePost(sample), sample);
  assert.doesNotThrow(() => validatePost({ ...sample, title: '花'.repeat(120), body: '🌷'.repeat(4000) }));
  assert.throws(() => validatePost({ ...sample, title: '🌷'.repeat(121) }));
  assert.throws(() => validateNote({ id: 'ok', text: '🌷'.repeat(2001) }));
  assert.throws(() => validateNote({ id: 'not/safe', text: 'example' }));
  assert.equal(cursor('9007199254740991'), Number.MAX_SAFE_INTEGER);
  for (const value of ['01', '9007199254740992', '-1', '1e3', 1]) assert.throws(() => cursor(value));
});

test('Access verifies RS256 signature, issuer, AUD, owner email and time claims', async () => {
  const issuer = 'https://fixture.cloudflareaccess.com';
  const env = { ACCESS_ISSUER: issuer, ACCESS_AUD: 'this-app', OWNER_EMAIL: 'owner@example.invalid' };
  const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const key = { ...publicKey.export({ format: 'jwk' }), kid: 'key-1', alg: 'RS256', use: 'sig' };
  const options = { now: 10_000, getKeys: async (iss) => { assert.equal(iss, issuer); return [key]; } };
  const encoded = (data) => Buffer.from(JSON.stringify(data)).toString('base64url');
  function signed(claims = {}, headers = {}, validSignature = true) {
    const message = `${encoded({ alg: 'RS256', kid: 'key-1', ...headers })}.${encoded({
      iss: issuer, aud: ['this-app'], email: 'OWNER@example.invalid', exp: 20, nbf: 1, sub: 'fixture-user', ...claims,
    })}`;
    const signature = sign('RSA-SHA256', Buffer.from(validSignature ? message : message + 'x'), privateKey).toString('base64url');
    return new Request('https://worker.example.invalid/authorize', { headers: { 'Cf-Access-Jwt-Assertion': `${message}.${signature}` } });
  }
  assert.equal(await verifyAccessOwner(signed(), env, options), true);
  for (const claims of [{ iss: 'https://other.cloudflareaccess.com' }, { aud: ['different-app'] }, { aud: 'this-app' },
    { email: 'someone@example.invalid' }, { exp: 10 }, { nbf: 11 }, { sub: '' }]) assert.equal(await verifyAccessOwner(signed(claims), env, options), false);
  assert.equal(await verifyAccessOwner(signed({}, { alg: 'none' }), env, options), false);
  assert.equal(await verifyAccessOwner(signed({}, { kid: 'unexpected' }), env, options), false);
  assert.equal(await verifyAccessOwner(signed({}, {}, false), env, options), false);
});

test('OAuth discovery, no CORS, authenticated route boundaries and real Access rejection', async (t) => {
  const { origin, pullToken } = await worker(t);
  const options = (value) => ({ headers: { Authorization: value } });
  const oauth = await fetch(`${origin}/.well-known/oauth-authorization-server`);
  assert.equal(oauth.status, 200);
  const info = await oauth.json();
  assert.deepEqual(info.scopes_supported, ['hortensia']);
  assert.equal(info.registration_endpoint, `${origin}/register`);
  for (const path of ['/.well-known/oauth-protected-resource', '/.well-known/oauth-protected-resource/mcp']) {
    const resource = await fetch(`${origin}${path}`);
    assert.equal(resource.status, 200, path);
    const metadata = await resource.json();
    assert.equal(metadata.resource, `${origin}/mcp`);
    assert.deepEqual(metadata.scopes_supported, ['hortensia']);
  }
  const unauth = await fetch(`${origin}/mcp`);
  assert.equal(unauth.status, 401);
  assert.match(unauth.headers.get('www-authenticate'), /oauth-protected-resource\/mcp/);
  assert.equal(unauth.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(unauth.headers.get('access-control-allow-origin'), null);
  assert.equal((await fetch(`${origin}/mcp`, options(`Bearer ${pullToken}`))).status, 401);
  const wrong = options(`Bearer ${randomBytes(32).toString('base64url')}`);
  for (const [method, path] of [['GET', '/pull'], ['GET', '/notes/status'], ['POST', '/ack'], ['POST', '/notes']]) {
    assert.equal((await fetch(`${origin}${path}`, { method })).status, 401);
    assert.equal((await fetch(`${origin}${path}`, { method, ...wrong })).status, 401);
  }
  assert.equal((await fetch(`${origin}/mcp`, { headers: { Origin: 'https://foreign.example.invalid' } })).status, 403);
  assert.equal((await fetch(`${origin}/mcp/other`)).status, 404);
  assert.equal((await fetch(`${origin}/token`, { method: 'GET' })).status, 404);
  const { url } = await registration(origin);
  for (const headers of [{}, { 'Cf-Access-Jwt-Assertion': 'invalid.jwt.signature' }, { 'X-Duet-Fixture-Access': 'fake' }]) {
    assert.equal((await fetch(url, { headers, redirect: 'manual' })).status, 403);
    assert.equal((await fetch(`${origin}/authorize`, { method: 'POST', headers, body: 'handle=forged' })).status, 403);
  }
  const foreignRegistration = await fetch(`${origin}/register`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ redirect_uris: ['https://foreign.example.invalid/callback'], token_endpoint_auth_method: 'none' }) });
  assert.equal(foreignRegistration.status, 400);
});

test('modern stateless discovery, header validation, legacy compatibility, and expired token rejection', async (t) => {
  const { origin, rpc, kv, tokens } = await worker(t, true);
  const discovery = await (await rpc('server/discover')).json();
  assert.equal(discovery.result.resultType, 'complete');
  assert.ok(discovery.result.supportedVersions.includes('2026-07-28'));
  assert.equal((await (await rpc('tools/list', {}, { headers: { 'Mcp-Method': 'ping' } })).json()).error.code, -32020);
  assert.equal((await (await rpc('ping', {}, { headers: { 'MCP-Protocol-Version': '2027-01-01' } })).json()).error.code, -32022);
  assert.equal((await rpc('no/such-method')).status, 404);
  assert.equal((await (await rpc('initialize', { protocolVersion: '2025-11-25' }, { modern: false })).json()).result.protocolVersion, '2025-11-25');
  assert.equal((await (await rpc('tools/list', {}, { modern: false })).json()).result.tools.length, 2);
  assert.equal((await rpc('notifications/initialized', {}, { modern: false, notification: true })).status, 202);
  assert.equal((await fetch(`${origin}/mcp`, { headers: { Authorization: `Bearer ${tokens.access_token}` } })).status, 405);
  assert.equal((await fetch(`${origin}/pull`, { headers: { Authorization: `Bearer ${tokens.access_token}` } })).status, 401);
  const { keys } = await kv.list({ prefix: 'token:' });
  assert.equal(keys.length, 1);
  const key = keys[0].name;
  const row = await kv.get(key, 'json');
  await kv.put(key, JSON.stringify({ ...row, expiresAt: Math.floor(Date.now() / 1000) - 1 }));
  assert.equal((await rpc('tools/list')).status, 401);
  const refreshed = await tokens.refresh();
  assert.equal(refreshed.status, 200);
  const { access_token } = await refreshed.json();
  assert.equal((await clients({ origin }, access_token).rpc('tools/list')).status, 200);
});

test('tool errors, plaintext, cursor filtering and idempotent acknowledgments', async (t) => {
  const { mac, rpc } = await worker(t, true);
  const invalid = await (await call(rpc, 'hortensia_post', { ...sample, body: 'x'.repeat(4001) })).json();
  assert.equal(invalid.result.isError, true);
  assert.match(invalid.result.content[0].text, /at most 4000/);
  assert.equal((await (await call(rpc, 'hortensia_notes_read', { arbitrary: 'input' })).json()).result.isError, true);
  assert.equal((await (await call(rpc, 'does_not_exist')).json()).error.code, -32602);
  const item1 = (await (await call(rpc, 'hortensia_post', sample)).json()).result.structuredContent;
  const item2 = (await (await call(rpc, 'hortensia_post', { ...sample, kind: 'done' })).json()).result.structuredContent;
  const pulled = (await (await mac('/pull?after=0')).json()).items;
  assert.deepEqual(pulled.map(({ createdAt, ...row }) => row), [{ ...sample, ...item1 }, { ...sample, ...item2, kind: 'done' }]);
  assert.equal((await mac('/pull?after=1.0')).status, 400);
  assert.equal((await mac('/ack', { through: '9999' })).status, 400);
  assert.equal((await mac('/ack', { through: item1.id })).status, 200);
  assert.equal((await mac('/ack', { through: item1.id })).status, 200);
  assert.deepEqual((await (await mac(`/pull?after=${item1.id}`)).json()).items, [pulled[1]]);
});

test('notes send idempotently, read in batches of twenty and report exactly the read IDs', async (t) => {
  const { mac, rpc } = await worker(t, true);
  assert.equal((await mac('/notes', { id: 'too-long', text: 'x'.repeat(2001) })).status, 400);
  for (let i = 1; i <= 25; i++) assert.equal((await mac('/notes', { id: `note-${i}`, text: `Plain <b>${i}</b>` })).status, 200);
  assert.equal((await mac('/notes', { id: 'note-1', text: 'duplicate should not replace' })).status, 200);
  const [left, right] = await Promise.all([call(rpc, 'hortensia_notes_read'), call(rpc, 'hortensia_notes_read')]);
  const [first, second] = (await Promise.all([left.json(), right.json()])).map((row) => row.result.structuredContent.notes)
    .sort((a, b) => b.length - a.length);
  assert.deepEqual([first.length, second.length], [20, 5]);
  assert.equal(first[0].text, 'Plain <b>1</b>');
  const allIds = [...first, ...second].map((row) => row.id);
  assert.equal(new Set(allIds).size, 25);
  assert.deepEqual((await (await mac('/notes/status')).json()).read, allIds);
  assert.deepEqual((await (await call(rpc, 'hortensia_notes_read')).json()).result.structuredContent.notes, []);
});

test('caps, 30-day item expiry, and note idempotency after eviction', async (t) => {
  const { db, mac, rpc } = await worker(t, true);
  const now = Date.now();
  await db.batch([
    db.prepare(`WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<501)
      INSERT INTO items(kind,title,body,created_ms) SELECT 'update', 't', 'b', CASE WHEN x=501 THEN ? ELSE ? END FROM n`).bind(now - 31 * 86400_000, now),
    db.prepare(`WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<200)
      INSERT INTO notes(id,text,created_ms) SELECT 'note-' || x,'text',? FROM n`).bind(now),
    db.prepare('INSERT INTO note_receipts(id) SELECT id FROM notes'),
  ]);
  const before = (await (await mac('/pull?after=499')).json()).items;
  assert.deepEqual(before.map((row) => row.id), ['500']);
  await prune(db, now);
  assert.equal(await db.prepare('SELECT COUNT(*) FROM items').first('COUNT(*)'), 500);
  assert.equal((await call(rpc, 'hortensia_post', sample)).status, 200);
  assert.equal(await db.prepare('SELECT COUNT(*) FROM items').first('COUNT(*)'), 500);
  const limited = (await (await mac('/pull')).json()).items;
  assert.equal(limited.length, 50);
  assert.equal(limited[0].id, '2');
  assert.equal((await mac('/notes', { id: 'newest', text: 'actual' })).status, 200);
  assert.equal(await db.prepare("SELECT id FROM notes WHERE id='note-1'").first(), null);
  assert.equal((await mac('/notes', { id: 'note-1', text: 'resend' })).status, 200);
  assert.equal(await db.prepare("SELECT id FROM notes WHERE id='note-1'").first(), null);
  assert.equal(await db.prepare('SELECT COUNT(*) FROM notes').first('COUNT(*)'), 200);
});

test('rolling MCP rate follows the grant across a token refresh; the Mac limit is separate', async (t) => {
  const { mac, rpc, tokens, origin, db } = await worker(t, true);
  for (let i = 0; i < 60; i++) assert.equal((await rpc('ping')).status, 200);
  assert.equal((await rpc('ping')).status, 429);
  const rotated = await tokens.refresh();
  assert.equal(rotated.status, 200);
  const { access_token } = await rotated.json();
  assert.equal((await clients({ origin }, access_token).rpc('ping')).status, 429);
  for (let i = 0; i < 30; i++) assert.equal((await mac('/pull')).status, 200);
  assert.equal((await mac('/notes/status')).status, 429);
  await db.prepare('UPDATE rate_limit SET at_ms = ?').bind(Date.now() - 60_001).run();
  assert.equal((await mac('/pull')).status, 200);
});

test('rate-limit keys give one key per IPv4 address and per expanded IPv6 /64', () => {
  const key = (ip) => clientKey(new Request('https://x.invalid/', { headers: ip === undefined ? {} : { 'CF-Connecting-IP': ip } }));
  assert.equal(key('2001:db8:a:b::1'), '2001:0db8:000a:000b');
  assert.equal(key('2001:0DB8:000a:b:1:2:3:4'), '2001:0db8:000a:000b');
  assert.equal(key('2001:db8::1'), '2001:0db8:0000:0000');
  assert.equal(key('2001:db8:0:0:1::'), '2001:0db8:0000:0000');
  assert.equal(key('::ffff:1.2.3.4'), '1.2.3.4');
  assert.equal(key('1.2.3.4'), '1.2.3.4');
  for (const bad of ['bogus::1::2', '1:2:3', '', undefined, '12345::1']) assert.equal(key(bad), 'unknown');
});
