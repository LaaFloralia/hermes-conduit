const decoder = new TextDecoder('utf-8', { fatal: true });
const cache = new Map();

function unbase64url(value) {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new Error('invalid JWT encoding');
  return Uint8Array.from(atob(value.replaceAll('-', '+').replaceAll('_', '/')), (byte) => byte.charCodeAt(0));
}

async function teamCerts(issuer, kid, now) {
  let entry = cache.get(issuer);
  if (!entry || entry.until <= now || (!entry.keys.some((key) => key.kid === kid) && entry.fetchedAt + 30_000 < now)) {
    const response = await fetch(`${issuer}/cdn-cgi/access/certs`, { redirect: 'error', signal: AbortSignal.timeout(5000) });
    if (!response.ok) throw new Error('unavailable access certs');
    const { keys } = await response.json();
    if (!Array.isArray(keys)) throw new Error('invalid access certs');
    entry = { keys, fetchedAt: now, until: now + 300_000 };
    cache.set(issuer, entry);
  }
  return entry.keys;
}

export async function verifyAccessOwner(request, env, { now = Date.now(), getKeys = teamCerts } = {}) {
  const jwt = request.headers.get('Cf-Access-Jwt-Assertion');
  const { ACCESS_ISSUER: issuer, ACCESS_AUD: aud, OWNER_EMAIL: email } = env;
  if (!jwt || jwt.length > 8192 || !aud || !email || !/^https:\/\/[a-z0-9-]+\.cloudflareaccess\.com$/.test(issuer ?? '')) return false;
  try {
    const parts = jwt.split('.');
    if (parts.length !== 3) return false;
    const [encodedHeader, encodedClaims, signature] = parts;
    const header = JSON.parse(decoder.decode(unbase64url(encodedHeader)));
    if (header.alg !== 'RS256' || typeof header.kid !== 'string' || !header.kid || header.crit !== undefined) return false;
    const claims = JSON.parse(decoder.decode(unbase64url(encodedClaims)));
    const seconds = Math.floor(now / 1000);
    if (claims.iss !== issuer || !Array.isArray(claims.aud) || !claims.aud.includes(aud)
      || !Number.isSafeInteger(claims.exp) || claims.exp <= seconds
      || (claims.nbf !== undefined && (!Number.isSafeInteger(claims.nbf) || claims.nbf > seconds))
      || typeof claims.email !== 'string' || claims.email.toLowerCase() !== email.toLowerCase()
      || typeof claims.sub !== 'string' || !claims.sub) return false;
    const jwk = (await getKeys(issuer, header.kid, now)).find((key) =>
      key.kid === header.kid && key.kty === 'RSA' && (!key.alg || key.alg === 'RS256') && (!key.use || key.use === 'sig'));
    if (!jwk) return false;
    const key = await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
    return await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, unbase64url(signature), new TextEncoder().encode(`${encodedHeader}.${encodedClaims}`));
  } catch {
    return false;
  }
}

export async function hasPullToken(request, expected) {
  const match = /^Bearer ([A-Za-z0-9_-]{43})$/i.exec(request.headers.get('Authorization') ?? '');
  if (!match || !/^[a-f0-9]{64}$/.test(expected ?? '')) return false;
  const wanted = Uint8Array.from(expected.match(/../g), (hex) => Number.parseInt(hex, 16));
  const actual = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(match[1]));
  return crypto.subtle.timingSafeEqual(actual, wanted);
}
