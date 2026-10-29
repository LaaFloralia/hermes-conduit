#!/bin/sh
# Publish the Bridge on its own tailnet HTTPS port through Tailscale Serve.
#
# Only the dedicated port is added. 8443 (Console/Usage) and 8444 (Hermes
# dashboard/Conduit) are read before and after, and the change is refused and
# rolled back if either of them differs. Funnel is never used, and the service
# itself only listens on 127.0.0.1.

set -eu

BRIDGE_DIR=$(cd -P "$(dirname "$0")/.." && pwd)
TS=${LAA_BRIDGE_TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}
HTTPS_PORT=${LAA_BRIDGE_HTTPS_PORT:-8445}
PORT=${LAA_BRIDGE_PORT:-9137}
GUARD="$BRIDGE_DIR/scripts/serve-guard.py"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

if [ ! -x "$TS" ]; then
  echo "tailscale CLI not found at $TS" >&2
  exit 1
fi

curl -fsS "http://127.0.0.1:$PORT/v1/health" >/dev/null || {
  echo "the Bridge is not answering on 127.0.0.1:$PORT; install it first" >&2
  exit 1
}

"$TS" serve status --json > "$WORK/before.json"

free_status=0
python3 "$GUARD" free "$WORK/before.json" "$HTTPS_PORT" > "$WORK/free.txt" 2>&1 || free_status=$?
case "$free_status" in
  0) ;;
  3)
    cat "$WORK/free.txt"
    echo "nothing to do: https://<tailnet>:$HTTPS_PORT is already configured; leaving it untouched"
    exit 0
    ;;
  *)
    cat "$WORK/free.txt" >&2
    exit 1
    ;;
esac

echo "adding https://<tailnet>:$HTTPS_PORT -> http://127.0.0.1:$PORT"
if ! "$TS" serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$PORT"; then
  echo "tailscale serve refused the new entry; nothing else was changed" >&2
  exit 1
fi

"$TS" serve status --json > "$WORK/after.json"
if ! python3 "$GUARD" guard "$WORK/before.json" "$WORK/after.json" "$HTTPS_PORT"; then
  echo "rolling back the new Serve entry only" >&2
  "$TS" serve --https="$HTTPS_PORT" off || true
  exit 1
fi

HOST=$("$TS" status --json | python3 -c 'import json,sys; print((json.load(sys.stdin)["Self"]["DNSName"]).rstrip("."))')
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$HOST:$HTTPS_PORT/v1/health" || true)
case "$code" in
  200) echo "verified: https://$HOST:$HTTPS_PORT/v1/health -> 200" ;;
  *)
    echo "the Serve entry exists but https://$HOST:$HTTPS_PORT/v1/health returned '$code'" >&2
    echo "removing the new entry to leave Serve as it was" >&2
    "$TS" serve --https="$HTTPS_PORT" off || true
    exit 1
    ;;
esac
