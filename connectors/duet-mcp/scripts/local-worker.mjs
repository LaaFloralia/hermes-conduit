import { createHash, randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { build } from 'esbuild';
import { Miniflare } from 'miniflare';

const root = new URL('../', import.meta.url);
let bundle;
async function compiled() {
  bundle ??= build({
    stdin: { contents: `
      import { createConnector } from './src/connector.mjs';
      import { verifyAccessOwner } from './src/access.mjs';
      export default createConnector({
        verifyOwner: (request, env) => {
          const origin = new URL(request.url).origin;
          if (origin === env.CONNECTOR_ORIGIN && origin.startsWith('http://127.0.0.1:')
            && env.FIXTURE_ACCESS && request.headers.get('X-Duet-Fixture-Access') === env.FIXTURE_ACCESS) return true;
          return verifyAccessOwner(request, env);
        },
        allowedRedirect: (uri, origin) => origin.startsWith('http://127.0.0.1:') && uri === origin + '/callback',
      });`, resolveDir: root.pathname, sourcefile: 'local-only-worker.mjs' },
    bundle: true, platform: 'neutral', mainFields: ['module', 'main'], format: 'esm', external: ['cloudflare:*'], write: false,
  }).then(({ outputFiles }) => outputFiles[0].text);
  return bundle;
}

async function loopbackPort() {
  const server = createServer();
  await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
  const { port } = server.address();
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  return port;
}

export async function localWorker() {
  const pullToken = randomBytes(32).toString('base64url');
  const access = randomBytes(32).toString('base64url');
  const port = await loopbackPort();
  const origin = `http://127.0.0.1:${port}`;
  const mf = new Miniflare({
    port, host: '127.0.0.1', modules: true, script: await compiled(), compatibilityDate: '2026-07-30',
    d1Databases: ['DB'], kvNamespaces: ['OAUTH_KV'], bindings: {
      CONNECTOR_ORIGIN: origin, ACCESS_ISSUER: 'https://fixture.cloudflareaccess.com', ACCESS_AUD: 'fixture-aud',
      OWNER_EMAIL: 'owner@example.invalid', FIXTURE_ACCESS: access, PULL_TOKEN_SHA256: createHash('sha256').update(pullToken).digest('hex'),
    },
  });
  try {
    await mf.ready;
    const db = await mf.getD1Database('DB');
    for (const filename of ['0001_duet.sql', '0002_note_receipts.sql']) {
      const sql = await readFile(new URL(`migrations/${filename}`, root), 'utf8');
      await db.batch(sql.split(';').map((chunk) => chunk.trim()).filter(Boolean).map((stmt) => db.prepare(stmt)));
    }
    const kv = await mf.getKVNamespace('OAUTH_KV');
    return { origin, pullToken, access, db, kv, close: () => mf.dispose() };
  } catch (error) {
    await mf.dispose();
    throw error;
  }
}
