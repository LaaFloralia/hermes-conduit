#!/bin/sh
# One-command rollback: remove the Bridge's own Serve entry, stop and unload the
# LaunchAgent, and report what is left.
#
# Nothing else is touched: Hermes, Paseo, Linear, Syncthing, cron and the
# existing 8443/8444 Serve entries keep running. State stays on disk so a later
# reinstall keeps paired devices.

set -eu

BRIDGE_DIR=$(cd -P "$(dirname "$0")/.." && pwd)
PORT=${LAA_BRIDGE_PORT:-9137}
TS=${LAA_BRIDGE_TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}

echo "1/3 removing the Bridge's Tailscale Serve entry"
"$BRIDGE_DIR/scripts/tailscale-serve-remove.sh" || echo "  (Serve entry already absent or removal reported above)"

echo "2/3 stopping and unloading com.laa.bridge"
"$BRIDGE_DIR/scripts/uninstall.sh"

echo "3/3 verifying"
if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then
  echo "  FAIL: 127.0.0.1:$PORT still answers" >&2
  exit 1
fi
echo "  ok: 127.0.0.1:$PORT closed"
echo "  existing serve entries:"
"$TS" serve status | sed 's/^/    /'
