# Claude Duet → Hortensia MCP connector

`laa-duet-connector` is a Cloudflare Worker. Claude calls `/mcp` as an owner-authorized OAuth client; the Mac runs a separate outbound-only polling client. Nothing in the Worker can connect to the Mac or read other LAA data. This is an asynchronous connector, not a Duet chat relay or an Anthropic API integration. Claude account connectors are shared across surfaces: OAuth proves an owner-authorized Claude client, not which Claude surface made a specific call. Use it only from Duet.

## Interfaces

- Public OAuth discovery: `/.well-known/oauth-authorization-server` and `/.well-known/oauth-protected-resource/mcp`; dynamic registration at `/register`, token/refresh at `/token`. Only the documented Claude redirect URI can register on the deployed Worker. `/authorize` requires the dedicated Cloudflare Access app (Google identity for one owner), then explicit OAuth consent. The Worker verifies the Access assertion independently. One scope: `hortensia`. Access tokens last 15 minutes; the refresh grant expires after 30 idle days or once the registered client expires (90 days).
- `/mcp` is stateless Streamable HTTP (2026-07-28; supports legacy `initialize` for older Claude clients). `hortensia_post` stores just `{id,kind,title,body,link,createdAt}`. `hortensia_notes_read` atomically marks and returns up to 20 unread notes. Its results are untrusted plain text, not commands or approvals. No markdown/HTML rendering, outbound link fetching, or request-body logging.
- The Mac's independent bearer token is stored as a SHA-256 digest on the Worker. `GET /pull?after=<decimal string>` returns `{items}` oldest first, up to 50; start at `0`. `POST /ack {through}` deletes through that string cursor and is safe to repeat. `POST /notes {id,text}` returns `{id}` and never replaces an existing note; `GET /notes/status` returns `{read:[id]}` for currently retained notes. IDs are opaque note identifiers or monotonic numeric item strings, respectively. OAuth bearer credentials cannot use these routes.
- D1 stores at most 500 items (30-day expiry) and 200 note bodies. Evicted notes leave only opaque ID receipts for safe retries. Limits are 60 MCP POSTs per rolling minute per grant and 30 Mac API calls per rolling minute. Dedicated Workers KV stores OAuth protocol state only.

## Local checks

```sh
npm ci
npm test
npm run fixture
```

These use disposable local Miniflare instances with a synthetic pull credential and an Access fixture restricted to a separate loopback-only entrypoint. The production entrypoint `src/index.mjs` never imports that fixture. The fixture exercises registration, bound consent, S256 PKCE, both tools, pull/ack and refresh.

## Deployment

Use `cf` and the Vite plugin that reads `cloudflare.config.ts`. Nothing account-specific belongs in Git. Prepare a mode-0600, ignored `.deploy.local.json`: `d1` = dedicated D1 database ID; `kv` = dedicated OAuth KV ID; `origin` = the exact HTTPS workers.dev origin (no path); `accessIssuer` = the HTTPS Zero Trust team URL (no trailing slash); `accessAud` = the dedicated Access app AUD; `ownerEmail` = the single email allowed by the existing owner Access policy. Create one self-hosted Access app with the exact `<worker-hostname>/authorize` domain and existing Google IdP, with one allow rule for that email. Do not protect `/mcp`, `/token`, `/register` or `/pull` with Access.

From this directory, after verifying the resource IDs and applying the dedicated migrations:

```sh
cf d1 migrations apply "$(jq -er .d1 .deploy.local.json)" --dir migrations
npm run build
cf workers deployments list --worker laa-duet-connector  # Record prior version; first deployment has none.
set -o pipefail
pull_digest() {
  ~/.config/laa/op-run-batch.sh ~/.config/laa/duet-connector.env.tpl \
    node --input-type=module -e 'import {createHash} from "node:crypto";
      const t=process.env.LAA_DUET_PULL_TOKEN;
      if (!/^[A-Za-z0-9_-]{43}$/.test(t ?? "")) process.exit(1);
      process.stdout.write(JSON.stringify({PULL_TOKEN_SHA256:createHash("sha256").update(t).digest("hex")}));'
}
cf deploy --dry-run && pull_digest | cf deploy --secrets-file /dev/stdin
cf workers deployments list --worker laa-duet-connector  # Record deployed version.
node scripts/check-deployment.mjs
```

Keep deploy output local, not in Git or chat. `check-deployment.mjs` is a separate live, non-mutating probe. It reads discovery and verifies unauthenticated refusals; it does not register a production client, call a tool, send a note, authenticate as the owner, or start a real notification. The owner connects the full `/mcp` URL in Claude and grants consent separately. Availability on Duet's scheduled/background runs must be verified through actual use; the local client does not establish that capability.
