import { readFileSync } from 'node:fs';
import { bindings, defineConfig, triggers } from 'cf/config';

// Account-specific IDs and owner identity are never checked into this public repo.
const local = JSON.parse(readFileSync(new URL('./.deploy.local.json', import.meta.url), 'utf8'));
for (const key of ['d1', 'kv', 'accessIssuer', 'accessAud', 'ownerEmail', 'origin']) {
  if (typeof local[key] !== 'string' || !local[key]) throw new Error(`Missing deploy setting: ${key}`);
}

export default defineConfig({
  worker: {
    name: 'laa-duet-connector',
    entrypoint: 'src/index.mjs',
    compatibilityDate: '2026-07-30',
    workersDev: true,
    previewUrls: false,
    observability: { enabled: false },
    triggers: [triggers.scheduled({ schedule: '17 * * * *' })],
    env: {
      DB: bindings.d1({ name: 'laa-duet-connector', id: local.d1 }),
      OAUTH_KV: bindings.kv({ id: local.kv }),
      CONNECTOR_ORIGIN: bindings.text(local.origin),
      ACCESS_ISSUER: bindings.text(local.accessIssuer),
      ACCESS_AUD: bindings.text(local.accessAud),
      OWNER_EMAIL: bindings.text(local.ownerEmail),
      PULL_TOKEN_SHA256: bindings.secret(),
    },
  },
});
