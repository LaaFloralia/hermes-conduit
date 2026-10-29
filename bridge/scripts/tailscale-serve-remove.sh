#!/bin/sh
# Remove only the Bridge's own Tailscale Serve port.
#
# `tailscale serve --https=<port> off` touches one port. This script never runs
# `tailscale serve reset` (that would drop 8443/8444 too) and never changes the
# Bridge process itself.

set -eu

BRIDGE_DIR=$(cd -P "$(dirname "$0")/.." && pwd)
TS=${LAA_BRIDGE_TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}
HTTPS_PORT=${LAA_BRIDGE_HTTPS_PORT:-8445}
GUARD="$BRIDGE_DIR/scripts/serve-guard.py"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

"$TS" serve status --json > "$WORK/before.json"
python3 - "$WORK/before.json" "$HTTPS_PORT" <<'PY'
import json, sys
status = json.load(open(sys.argv[1], encoding="utf-8"))
port = str(sys.argv[2])
served = list((status.get("TCP") or {}).keys()) + [k.rsplit(":", 1)[-1] for k in (status.get("Web") or {})]
sys.exit(0 if port in served else 3)
PY
present=$?
if [ "$present" = 3 ]; then
  echo "https port $HTTPS_PORT is not served; nothing to remove"
  exit 0
fi

"$TS" serve --https="$HTTPS_PORT" off
"$TS" serve status --json > "$WORK/after.json"
if ! python3 "$GUARD" guard "$WORK/before.json" "$WORK/after.json" "$HTTPS_PORT"; then
  echo "an existing serve entry changed while removing $HTTPS_PORT; inspect 'tailscale serve status' by hand" >&2
  exit 1
fi
python3 - "$WORK/after.json" "$HTTPS_PORT" <<'PY'
import json, sys
status = json.load(open(sys.argv[1], encoding="utf-8"))
port = str(sys.argv[2])
served = list((status.get("TCP") or {}).keys()) + [k.rsplit(":", 1)[-1] for k in (status.get("Web") or {})]
print(f"port {port} removed" if port not in served else f"port {port} is still served")
sys.exit(1 if port in served else 0)
PY
