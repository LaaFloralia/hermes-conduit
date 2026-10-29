#!/usr/bin/env node
// App Store Connect API from a shell: the LAA TestFlight upload's half of
// scripts/laa/testflight.sh, and a way to ask the API one question by hand.
//
//   node scripts/laa/asc.mjs GET /v1/bundleIds?filter[identifier]=com.laa-inc.laa
//   node scripts/laa/asc.mjs POST /v1/betaGroups '{"data":{...}}'
//   node scripts/laa/asc.mjs wait-build <appId> <buildNumber> <betaGroupId>
//
// The key material comes only from the environment, which testflight.sh gets
// from 1Password (ASC_KEY, ASC_KEY_ID, ASC_ISSUER_ID); nothing here reads a
// file or prints a secret. A request prints {"status": <http status>,
// "body": <parsed JSON or null>} on stdout and exits 0 for any answer the API
// gave, 1 when the request itself failed. wait-build exits 0 only once the
// build is VALID and the group can see it.
import crypto from 'node:crypto';

const API = 'https://api.appstoreconnect.apple.com';
const { ASC_KEY, ASC_KEY_ID, ASC_ISSUER_ID } = process.env;

/** The ES256 bearer token Apple accepts; 20 minutes, the documented maximum. */
function token() {
  if (!ASC_KEY || !ASC_KEY_ID || !ASC_ISSUER_ID) {
    console.error('asc: ASC_KEY, ASC_KEY_ID and ASC_ISSUER_ID must be set ' +
      '(scripts/laa/testflight.sh takes them from 1Password)');
    process.exit(1);
  }
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const header = encode({ alg: 'ES256', kid: ASC_KEY_ID, typ: 'JWT' });
  const claims = encode({ iss: ASC_ISSUER_ID, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' });
  const signature = crypto.sign('sha256', Buffer.from(`${header}.${claims}`),
    { key: ASC_KEY, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${header}.${claims}.${signature}`;
}

/** One API call. A 404 or a 409 is an answer, not a failure. */
async function call(method, path, body) {
  let response;
  try {
    response = await fetch(path.startsWith('http') ? path : `${API}${path}`, {
      method,
      headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
      body,
    });
  } catch (error) {
    console.error(`asc: ${method} ${path.split('?')[0]} failed: ${error.message}`);
    process.exit(1);
  }
  const text = await response.text();
  let parsed = null;
  if (text) {
    try { parsed = JSON.parse(text); } catch { parsed = text; }
  }
  return { status: response.status, body: parsed };
}

const [command, ...args] = process.argv.slice(2);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

if (command === 'wait-build') {
  // The upload finishes server-side minutes after xcodebuild returns: the
  // build appears as PROCESSING and then VALID (or INVALID with the reason).
  // Only once it is VALID can TestFlight hand it to a group.
  const [appId, buildNumber, groupId] = args;
  if (!appId || !buildNumber || !groupId) {
    console.error('usage: asc.mjs wait-build <appId> <buildNumber> <betaGroupId>');
    process.exit(1);
  }
  const deadline = Date.now() + Number(process.env.ASC_WAIT_SECONDS || 45 * 60) * 1000;
  let buildId = null;
  let lastState = null;
  while (Date.now() < deadline) {
    if (!buildId) {
      const listing = await call('GET',
        `/v1/builds?filter[app]=${appId}&filter[version]=${buildNumber}` +
        '&fields[builds]=version,processingState,expired,uploadedDate&limit=5');
      if (listing.status !== 200) {
        console.error(`asc: listing builds answered ${listing.status}: ` +
          `${JSON.stringify(listing.body?.errors ?? listing.body)}`);
        process.exit(1);
      }
      const match = (listing.body?.data ?? []).find((build) => build.attributes.version === buildNumber);
      if (!match) {
        console.log(`waiting: build ${buildNumber} has not reached App Store Connect yet`);
        await sleep(30_000);
        continue;
      }
      buildId = match.id;
    }
    const build = await call('GET', `/v1/builds/${buildId}?fields[builds]=version,processingState,expired`);
    const state = build.body?.data?.attributes?.processingState ?? 'UNKNOWN';
    if (state !== lastState) {
      console.log(`build ${buildNumber} (${buildId}): ${state}`);
      lastState = state;
    }
    if (state === 'VALID') {
      // A group with access to every build is assigned on its own; ask, so a
      // build nobody can install is a failure here and not a surprise later.
      // The key may not list a build's groups (GET /v1/builds/{id}/betaGroups
      // answered 403, 2026-10-29), so ask the group instead.
      const group = await call('GET',
        `/v1/betaGroups/${groupId}?fields[betaGroups]=name,isInternalGroup,hasAccessToAllBuilds`);
      if (group.status !== 200) {
        console.error(`asc: reading group ${groupId} answered ${group.status}`);
        process.exit(1);
      }
      const { name, isInternalGroup, hasAccessToAllBuilds } = group.body.data.attributes;
      let available = Boolean(isInternalGroup && hasAccessToAllBuilds);
      if (!available) {
        const linked = await call('GET', `/v1/betaGroups/${groupId}/relationships/builds?limit=200`);
        available = linked.status === 200 && (linked.body?.data ?? []).some((b) => b.id === buildId);
      }
      if (!available) {
        console.error(`asc: build ${buildNumber} is VALID but not available to ${name} (${groupId})`);
        console.error('asc: add the build to the group in App Store Connect, then upload again');
        process.exit(1);
      }
      const detail = await call('GET', `/v1/builds/${buildId}/buildBetaDetail`);
      const internal = detail.body?.data?.attributes?.internalBuildState ?? 'unknown';
      console.log(`build ${buildNumber} is VALID and available to ${name} (${groupId}); internal state ${internal}`);
      process.exit(0);
    }
    if (state === 'INVALID' || state === 'FAILED') {
      console.error(`asc: build ${buildNumber} is ${state}; App Store Connect says why in TestFlight`);
      process.exit(1);
    }
    await sleep(30_000);
  }
  console.error(`asc: build ${buildNumber} was still ${lastState} at the deadline`);
  process.exit(1);
}

if (command === 'GET' || command === 'POST' || command === 'PATCH' || command === 'DELETE') {
  const [path, body] = args;
  if (!path) {
    console.error(`usage: asc.mjs ${command} <path> [json body]`);
    process.exit(1);
  }
  if (body) {
    try { JSON.parse(body); } catch (error) {
      console.error(`asc: the body is not JSON: ${error.message}`);
      process.exit(1);
    }
  }
  const result = await call(command, path, body);
  console.log(JSON.stringify(result));
  process.exit(0);
}

console.error('usage: asc.mjs GET|POST|PATCH|DELETE <path> [json body]');
console.error('       asc.mjs wait-build <appId> <buildNumber> <betaGroupId>');
process.exit(1);
