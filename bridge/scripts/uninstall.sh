#!/bin/sh
# Stop and unload the Bridge LaunchAgent. State (devices, idempotency ledger) is
# kept by default so a reinstall keeps paired devices; pass --purge-state to
# delete it as well. Tailscale Serve is not touched: use
# scripts/tailscale-serve-remove.sh (rollback.sh does both).

set -eu

BRIDGE_DIR=$(cd -P "$(dirname "$0")/.." && pwd)
LABEL=${LAA_BRIDGE_LABEL:-com.laa.bridge}
PORT=${LAA_BRIDGE_PORT:-9137}
STATE_DIR=${LAA_BRIDGE_STATE_DIR:-$HOME/.local/state/laa-bridge}
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
CLI_LINK="$HOME/.local/bin/laa-bridge"

launchctl bootout "gui/$(id -u)" "$PLIST_DST" >/dev/null 2>&1 || launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST_DST"

if [ -L "$CLI_LINK" ]; then
  target=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CLI_LINK")
  case "$target" in
    "$BRIDGE_DIR"/*) rm -f "$CLI_LINK"; echo "removed $CLI_LINK" ;;
    *) echo "left $CLI_LINK in place (it points at $target)" ;;
  esac
fi

if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then
  echo "warning: something still answers on 127.0.0.1:$PORT; the agent may not have stopped" >&2
  exit 1
fi
echo "stopped: nothing listens on 127.0.0.1:$PORT"

if [ "${1:-}" = "--purge-state" ]; then
  # Only removes devices and the idempotency ledger; every paired device must
  # pair again afterwards.
  rm -rf "$STATE_DIR"
  echo "purged state: $STATE_DIR"
else
  echo "kept state (devices, ledger): $STATE_DIR"
fi
