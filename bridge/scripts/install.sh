#!/bin/sh
# Install the Bridge as a launchd LaunchAgent and expose the CLI on PATH.
#
# This runs only from an agent-control gate on the owner's Mac:
#   laa-agent-control exec --provider local --label laa-bridge-install \
#     --timeout 120 -- /path/to/bridge/scripts/install.sh
# It does not touch Tailscale Serve; run scripts/tailscale-serve-add.sh after.

set -eu

BRIDGE_DIR=$(cd -P "$(dirname "$0")/.." && pwd)
LABEL=${LAA_BRIDGE_LABEL:-com.laa.bridge}
PORT=${LAA_BRIDGE_PORT:-9137}
STATE_DIR=${LAA_BRIDGE_STATE_DIR:-$HOME/.local/state/laa-bridge}
PLIST_SRC="$BRIDGE_DIR/launchd/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
CLI_LINK="$HOME/.local/bin/laa-bridge"
LOG_DIR="$HOME/Library/Logs"

NODE=${LAA_BRIDGE_NODE:-$(python3 -c 'import os,shutil; print(os.path.realpath(shutil.which("node") or ""))')}
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
  echo "node not found; set LAA_BRIDGE_NODE to an absolute node binary" >&2
  exit 1
fi
NODE_MAJOR=$("$NODE" -p 'process.versions.node.split(".")[0]')
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "node $("$NODE" -v) is too old; 20.11 or newer is required" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.local/bin" "$LOG_DIR" "$STATE_DIR"
chmod 700 "$STATE_DIR"

# Refuse to take a port that some other process already owns.
if ! curl -fsS --max-time 2 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $PORT is already used by another process:" >&2
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2
    exit 1
  fi
fi

python3 - "$PLIST_SRC" "$PLIST_DST" "$NODE" "$BRIDGE_DIR" "$STATE_DIR" "$PORT" "$HOME" <<'PY'
import sys
src, dst, node, bridge_dir, state_dir, port, home = sys.argv[1:8]
text = open(src, encoding="utf-8").read()
placeholders = {
    "@@NODE@@": node,
    "@@BRIDGE_DIR@@": bridge_dir,
    "@@STATE_DIR@@": state_dir,
    "@@PORT@@": port,
    "@@HOME@@": home,
}
for key, value in placeholders.items():
    text = text.replace(key, value)
left = [key for key in placeholders if key in text]
if left:
    raise SystemExit(f"unsubstituted placeholders in the plist template: {left}")
open(dst, "w", encoding="utf-8").write(text)
PY
plutil -lint "$PLIST_DST" >/dev/null

# Reinstalling is allowed: unload the old definition before loading the new one.
launchctl bootout "gui/$(id -u)" "$PLIST_DST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

if ! curl -fsS --max-time 2 "http://127.0.0.1:$PORT/v1/health"; then
  echo "the agent did not become healthy on 127.0.0.1:$PORT" >&2
  echo "--- last log lines ---" >&2
  tail -n 20 "$LOG_DIR/$LABEL.error.log" "$LOG_DIR/$LABEL.log" 2>/dev/null >&2 || true
  launchctl print "gui/$(id -u)/$LABEL" 2>&1 | head -40 >&2 || true
  exit 1
fi

ln -sfn "$BRIDGE_DIR/bin/laa-bridge" "$CLI_LINK"
echo
echo "installed $LABEL from $BRIDGE_DIR"
echo "  listener : 127.0.0.1:$PORT"
echo "  state    : $STATE_DIR"
echo "  plist    : $PLIST_DST"
echo "  cli      : $CLI_LINK"
echo "next: $BRIDGE_DIR/scripts/tailscale-serve-add.sh   (tailnet HTTPS)"
echo "      laa-bridge pair                              (first device)"
