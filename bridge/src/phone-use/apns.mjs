// One ActivityKit push to APNs, from the CLI process that 1Password started
// with the LAA APNs key (APNS_KEY, APNS_KEY_ID). The key stays in memory.
import { createPrivateKey, createSign } from 'node:crypto';
import { connect } from 'node:http2';

const ORIGINS = { production: 'https://api.push.apple.com', sandbox: 'https://api.sandbox.push.apple.com' };
const b64url = (value) => Buffer.from(value).toString('base64url');

export function apnsJwt({ key, keyId, teamId, now = Date.now() }) {
  const unsigned = `${b64url(JSON.stringify({ alg: 'ES256', kid: keyId }))}.${b64url(JSON.stringify({ iss: teamId, iat: Math.floor(now / 1000) }))}`;
  const signature = createSign('SHA256').update(unsigned).sign({ key: createPrivateKey(key), dsaEncoding: 'ieee-p1363' });
  return `${unsigned}.${signature.toString('base64url')}`;
}

export function apnsSenderFromEnv(env = process.env) {
  const key = env.APNS_KEY, keyId = env.APNS_KEY_ID;
  if (!key || !keyId || key.startsWith('op://')) return null;
  const teamId = env.LAA_PHONE_USE_TEAM_ID || 'PAW258GB42';
  const topic = `${env.LAA_PHONE_USE_BUNDLE_ID || 'com.laa-inc.laa'}.push-type.liveactivity`;
  const once = ({ token, environment, payload }) => new Promise((resolve, reject) => {
    const client = connect(ORIGINS[environment] ?? ORIGINS.production);
    let done = false;
    const finish = (error, result) => {
      if (done) return;
      done = true; clearTimeout(timer); client.destroy();
      error ? reject(error) : resolve(result);
    };
    const timer = setTimeout(() => finish(Object.assign(new Error('apns timeout'), { code: 'apns_timeout' })), 10_000);
    client.on('error', (e) => finish(Object.assign(new Error('apns unreachable'), { code: e?.code ?? 'apns_unreachable' })));
    const body = JSON.stringify(payload);
    const request = client.request({
      ':method': 'POST', ':path': `/3/device/${token}`,
      authorization: `bearer ${apnsJwt({ key, keyId, teamId })}`,
      'apns-push-type': 'liveactivity', 'apns-topic': topic, 'apns-priority': '10',
      'content-type': 'application/json', 'content-length': Buffer.byteLength(body),
    });
    let status = 0, text = '';
    request.on('response', (headers) => { status = headers[':status']; });
    request.on('data', (chunk) => { if (text.length < 1024) text += chunk; });
    request.on('error', (e) => finish(Object.assign(new Error('apns request failed'), { code: e?.code ?? 'apns_failed' })));
    request.on('end', () => {
      if (status === 200) return finish(null, { status });
      let reason = 'apns_rejected';
      try { reason = JSON.parse(text).reason ?? reason; } catch {}
      finish(Object.assign(new Error(reason), { code: `apns_${status}_${reason}` }));
    });
    request.end(body);
  });
  // The token's environment follows the build's signing, which the app can
  // only guess (a Debug build may carry the production entitlement): a token
  // APNs calls bad in one environment is tried once in the other.
  // A connection that dropped before any answer (a cancelled HTTP/2 stream)
  // is tried once more; a timeout may have delivered, so it is not.
  const sent = async (push) => {
    try { return await once(push); }
    catch (error) {
      if (/^apns_(\d+_|timeout$)/.test(String(error.code))) throw error;
      return once(push);
    }
  };
  return async (push) => {
    try { return await sent(push); }
    catch (error) {
      if (!String(error.code).endsWith('_BadDeviceToken')) throw error;
      return { ...(await sent({ ...push, environment: push.environment === 'sandbox' ? 'production' : 'sandbox' })), switched: true };
    }
  };
}
