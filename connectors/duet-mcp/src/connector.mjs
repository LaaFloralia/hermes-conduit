import { OAuthProvider } from '@cloudflare/workers-oauth-provider';
import { hasPullToken, verifyAccessOwner } from './access.mjs';
import { cursor, InputError, jsonObject, readBytes, validateNote } from './input.mjs';
import { mcp } from './mcp.mjs';
import { ackItems, noteStatus, prune, pullItems, putNote, takeRate } from './store.mjs';

const SCOPE = 'hortensia';
const CLAUDE_REDIRECT = 'https://claude.ai/api/mcp/auth_callback';
const security = {
  'Cache-Control': 'no-store',
  'Content-Security-Policy': "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self' https://claude.ai",
  'Referrer-Policy': 'no-referrer',
  'Strict-Transport-Security': 'max-age=31536000',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
};
const oauth = new Map([
  ['/authorize', ['GET', 'POST']], ['/token', ['POST']], ['/register', ['POST']],
  ['/.well-known/oauth-authorization-server', ['GET']],
  ['/.well-known/oauth-protected-resource', ['GET']], ['/.well-known/oauth-protected-resource/mcp', ['GET']],
]);
const mac = new Map([['/pull', 'GET'], ['/ack', 'POST'], ['/notes', 'POST'], ['/notes/status', 'GET']]);
const escape = (value) => String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const jsonError = (error, status, headers) => Response.json({ error }, { status, headers });
// One IPv6 host usually holds a whole /64, so it counts as one client.
const clientKey = (request) => {
  const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  return ip.includes(':') ? ip.split(':').slice(0, 4).join(':') : ip;
};

function secured(response) {
  const headers = new Headers(response.headers);
  for (const name of [...headers.keys()]) if (name.toLowerCase().startsWith('access-control-')) headers.delete(name);
  for (const [name, value] of Object.entries(security)) headers.set(name, value);
  return new Response(response.body, { status: response.status, headers });
}

async function authorize(request, env, verifyOwner) {
  if (!await verifyOwner(request, env)) return jsonError('access_required', 403);
  const provider = env.OAUTH_PROVIDER;
  try {
    if (request.method === 'GET') {
      const auth = await provider.parseAuthRequest(request);
      if (auth.responseType !== 'code' || auth.codeChallengeMethod !== 'S256'
        || !/^[A-Za-z0-9_-]{43}$/.test(auth.codeChallenge ?? '') || auth.scope.some((scope) => scope !== SCOPE)) {
        return jsonError('S256 PKCE and the hortensia scope are required.', 400);
      }
      const consent = await provider.describeConsent(auth);
      const { handle, headers } = await provider.beginConsent(auth);
      headers.set('Content-Type', 'text/html; charset=utf-8');
      return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><title>Connect Claude to Hortensia</title>
<h1>Connect Claude to Hortensia</h1><p>Allow ${escape(consent.redirectHost ?? new URL(auth.redirectUri).hostname)} to post Claude Duet items and read unread Duet notes. This does not grant access to any other Hortensia data.</p>
<form action="/authorize" method="post"><input type="hidden" name="handle" value="${escape(handle)}"><button type="submit">Connect Claude</button></form></html>`, { headers });
    }
    if (request.headers.get('Origin') !== env.CONNECTOR_ORIGIN
      || request.headers.get('Content-Type')?.split(';')[0] !== 'application/x-www-form-urlencoded') {
      return jsonError('invalid_consent', 403);
    }
    const form = new URLSearchParams(new TextDecoder().decode(await readBytes(request, 2048)));
    if (form.getAll('handle').length !== 1) return jsonError('invalid_consent', 400);
    const { request: auth, headers } = await provider.approveConsent(request, form.get('handle'), { scope: [SCOPE] });
    const { redirectTo } = await provider.completeAuthorization({
      request: auth, userId: 'owner', scope: [SCOPE], props: { grantId: crypto.randomUUID() }, metadata: {},
    });
    headers.set('Location', redirectTo);
    return new Response(null, { status: 303, headers });
  } catch (error) {
    if (error instanceof InputError) return jsonError(error.message, error.status);
    return jsonError('invalid_authorization_request', 400);
  }
}

async function macApi(request, env, url) {
  if (!await hasPullToken(request, env.PULL_TOKEN_SHA256)) return jsonError('invalid_token', 401, { 'WWW-Authenticate': 'Bearer' });
  if (!await takeRate(env.DB, 'bridge', 30)) return jsonError('rate_limited', 429, { 'Retry-After': '60' });
  switch (url.pathname) {
    case '/pull': return Response.json(await pullItems(env.DB, cursor(url.searchParams.get('after') ?? '0', { zero: true })));
    case '/ack': {
      const payload = await jsonObject(request, 1024);
      if (Object.keys(payload).length !== 1) throw new InputError('Expected through cursor.');
      if (!await ackItems(env.DB, cursor(payload.through))) throw new InputError('Unknown through cursor.');
      return Response.json({ ok: true });
    }
    case '/notes': {
      const { id, text } = validateNote(await jsonObject(request, 25_000));
      return Response.json(await putNote(env.DB, id, text));
    }
    case '/notes/status': return Response.json(await noteStatus(env.DB));
  }
}

export function createConnector({ verifyOwner = verifyAccessOwner, allowedRedirect = (uri) => uri === CLAUDE_REDIRECT } = {}) {
  return {
    async fetch(request, env, ctx) {
      const run = async () => {
        const url = new URL(request.url);
        const path = url.pathname;
        const allowed = oauth.get(path);
        if (path !== '/mcp' && !allowed?.includes(request.method) && mac.get(path) !== request.method) return jsonError('not_found', 404);
        if (url.origin !== env.CONNECTOR_ORIGIN) return jsonError('not_found', 404);
        const origin = request.headers.get('Origin');
        if (origin !== null && origin !== url.origin) return jsonError('invalid_origin', 403);
        if (mac.has(path)) return macApi(request, env, url);
        const provider = new OAuthProvider({
          apiRoute: '/mcp', apiHandler: { fetch: mcp }, defaultHandler: { fetch: (req, bindings) => authorize(req, bindings, verifyOwner) },
          authorizeEndpoint: '/authorize', tokenEndpoint: '/token', clientRegistrationEndpoint: '/register',
          scopesSupported: [SCOPE], requiredScopes: [SCOPE], accessTokenTTL: 900, refreshTokenTTL: 30 * 86400,
          refreshTokenIdleTTL: 30 * 86400, onError: () => {},
          resourceMetadata: { resource: `${url.origin}/mcp`, authorization_servers: [url.origin], resource_name: 'Hortensia for Claude Duet' },
          clientRegistrationCallback: ({ clientMetadata }) => {
            if (!Array.isArray(clientMetadata.redirect_uris) || clientMetadata.redirect_uris.length !== 1
              || !allowedRedirect(clientMetadata.redirect_uris[0], url.origin)) return { description: 'Use the documented Claude OAuth callback.' };
          },
        });
        // Registration and token calls are unauthenticated by design. Cap them per
        // client address, so one caller cannot starve Claude's token refresh, and
        // keep a global ceiling on registration, which writes to the OAuth store.
        // /token has no global bucket on purpose: a shared one would let anyone
        // starve the refresh, and a rejected code or refresh writes nothing.
        if (path === '/register' || path === '/token') {
          const limited = (path === '/register' && !await takeRate(env.DB, 'register', 30))
            || !await takeRate(env.DB, `${path.slice(1)}:${clientKey(request)}`, path === '/register' ? 5 : 30);
          if (limited) return jsonError('rate_limited', 429, { 'Retry-After': '60' });
        }
        if (path === '/token' || path === '/register') request = new Request(request, { body: await readBytes(request, 16_384) });
        if (path === '/.well-known/oauth-protected-resource') request = new Request(`${url.origin}${path}/mcp`, request);
        return provider.fetch(request, env, ctx);
      };
      try { return secured(await run()); } catch (error) {
        return secured(error instanceof InputError ? jsonError(error.message, error.status) : jsonError('unavailable', 503));
      }
    },
    scheduled(_event, env, ctx) { ctx.waitUntil(prune(env.DB)); },
  };
}
