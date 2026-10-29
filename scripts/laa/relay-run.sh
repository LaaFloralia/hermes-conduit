#!/bin/bash
# Runs the LAA push relay: the service that sends com.laa-inc.laa's alerts and
# VoIP rings through APNs. launchd starts it (scripts/laa/relay-install.sh);
# it is not meant to be run by hand, though it works that way for a check.
#
# The APNs key never lives on disk outside this process: 1Password hands it
# over as APNS_KEY, this script writes it to a 0600 file in a private
# directory under ~/.config/laa/tmp-secrets — the relay needs a file — and the
# directory is removed when the relay exits.
#
# Environment:
#   LAA_RELAY_TEMPLATE    the 1Password template (default
#                         ~/.config/laa/conduit-relay-laa.env.tpl)
#   LAA_RELAY_HOME        the installed app and its data
#                         (default ~/.local/share/laa-conduit-relay-laa)
#   LAA_RELAY_PORT        default 9120
#   LAA_RELAY_PUBLIC_URL  default https://mac-mini.tailc9b8e7.ts.net:9443
#   LAA_RELAY_TEAM_ID     default PAW258GB42
#   LAA_RELAY_TOPIC       default com.laa-inc.laa
#   LAA_RELAY_WATCH_TOPIC default com.laa-inc.laa.watchkitapp
set -euo pipefail
set +x

# launchd starts this with almost no PATH; op and node live in Homebrew's bin.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

template="${LAA_RELAY_TEMPLATE:-$HOME/.config/laa/conduit-relay-laa.env.tpl}"
install_dir="${LAA_RELAY_HOME:-$HOME/.local/share/laa-conduit-relay-laa}"
secrets_root="$HOME/.config/laa/tmp-secrets"

# The first run has no credentials: 1Password injects them and this script
# runs again with them set. op run masks them in this process's output.
if [ "${LAA_RELAY_ENV_READY:-}" != 1 ]; then
  [ -f "$template" ] || { echo "relay: no 1Password template at $template" >&2; exit 1; }
  exec /Users/laa/.config/laa/op-run-batch.sh "$template" \
    env LAA_RELAY_ENV_READY=1 "$0" "$@"
fi

[ -n "${APNS_KEY:-}" ] || { echo "relay: APNS_KEY is empty" >&2; exit 1; }
[ -n "${APNS_KEY_ID:-}" ] || { echo "relay: APNS_KEY_ID is empty" >&2; exit 1; }
[ -f "$install_dir/app/src/server.mjs" ] || {
  echo "relay: the relay isn't installed at $install_dir (scripts/laa/relay-install.sh)" >&2
  exit 1
}
[ -d "$install_dir/data" ] || mkdir -p "$install_dir/data"

mkdir -p "$secrets_root"
chmod 700 "$secrets_root"
secrets="$(mktemp -d "$secrets_root/relay-apns.XXXXXX")"
key_path="$secrets/AuthKey_${APNS_KEY_ID}.p8"
(umask 077; printf '%s\n' "$APNS_KEY" > "$key_path")

cd "$install_dir/app"

export HOST="${LAA_RELAY_HOST:-127.0.0.1}"
export PORT="${LAA_RELAY_PORT:-9120}"
export PUBLIC_URL="${LAA_RELAY_PUBLIC_URL:-https://mac-mini.tailc9b8e7.ts.net:9443}"
export DATA_PATH="$install_dir/data/relay.json"
export APNS_KEY_PATH="$key_path"
export APNS_KEY_ID
export APNS_TEAM_ID="${LAA_RELAY_TEAM_ID:-PAW258GB42}"
export APNS_TOPIC="${LAA_RELAY_TOPIC:-com.laa-inc.laa}"
export APNS_WATCH_TOPIC="${LAA_RELAY_WATCH_TOPIC:-com.laa-inc.laa.watchkitapp}"
# tailscale serve is the one hop in front of it, and it sets X-Forwarded-For.
export TRUST_PROXY=1

node src/server.mjs &
node_pid=$!

cleanup() {
  kill "$node_pid" 2>/dev/null || true
  wait "$node_pid" 2>/dev/null || true
  rm -rf "$secrets"
}
trap cleanup EXIT INT TERM

wait "$node_pid"
