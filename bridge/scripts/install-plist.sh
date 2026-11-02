#!/bin/sh
# Render the LaunchAgent plist into place.
#
# Split out of install.sh so the rendering can be tested without launchctl:
#   install-plist.sh <template> <destination> <node> <bridge-dir> <state-dir> <port> <home>
#
# The template is rendered to a 0600 temporary file beside the destination, the
# operator's three opt-in settings are carried over from the live plist, and the
# result replaces the live plist only after it passes `plutil -lint`. A live
# plist that cannot be read stops the install with the live plist untouched.
set -eu

if [ "$#" -ne 7 ]; then
  echo "usage: install-plist.sh <template> <destination> <node> <bridge-dir> <state-dir> <port> <home>" >&2
  exit 2
fi

PLIST_SRC=$1
PLIST_DST=$2
NODE=$3
BRIDGE_DIR=$4
STATE_DIR=$5
PORT=$6
HOME_DIR=$7

DEST_DIR=$(dirname "$PLIST_DST")
mkdir -p "$DEST_DIR"

TMP=""
cleanup() {
  if [ -n "$TMP" ]; then rm -f "$TMP"; fi
}
trap cleanup EXIT INT TERM

# Same directory as the destination, so the final mv is an atomic rename.
umask 077
TMP=$(mktemp "$DEST_DIR/.$(basename "$PLIST_DST").XXXXXX")

python3 - "$PLIST_SRC" "$TMP" "$NODE" "$BRIDGE_DIR" "$STATE_DIR" "$PORT" "$HOME_DIR" <<'PY'
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

python3 "$BRIDGE_DIR/scripts/preserve-plist-env.py" "$PLIST_DST" "$TMP"
plutil -lint "$TMP" >/dev/null
chmod 600 "$TMP"
mv -f "$TMP" "$PLIST_DST"
TMP=""
