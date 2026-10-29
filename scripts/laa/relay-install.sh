#!/bin/bash
# Installs the LAA push relay: the service behind com.laa-inc.laa's alerts and
# VoIP rings. It runs the relay this Mac already has — the one shipped with
# the conduit_push plugin — under its own launchd job and its own APNs key, so
# the App Store app's relay (push.milim.dev) and the eight profiles paired to
# it are untouched.
#
#   scripts/laa/relay-install.sh            install and start
#   scripts/laa/relay-install.sh status     what is running
#   scripts/laa/relay-install.sh uninstall  stop and remove (the rollback)
#
# The relay is bound to 127.0.0.1:9120 and published on the tailnet only, at
# https://mac-mini.tailc9b8e7.ts.net:9443, which is the CONDUIT_DEFAULT_RELAY_URL
# in project-laa.yml. Both the phone and this Mac must be on the tailnet, as
# Hermes already requires.
#
# One relay serves one app bundle: APNS_TOPIC is com.laa-inc.laa. A Hermes
# profile pairs with exactly one relay, so the LAA app is paired by a profile
# that pushes here — see docs/LAA_BUILD.md.
set -euo pipefail
set +x

cd "$(dirname "$0")/../.."
repo="$PWD"
action="${1:-install}"
label="com.laa.conduit-relay-laa"
plist="$HOME/Library/LaunchAgents/$label.plist"
install_dir="${LAA_RELAY_HOME:-$HOME/.local/share/laa-conduit-relay-laa}"
source_dir="${LAA_RELAY_SOURCE:-$HOME/.hermes/plugins/conduit_push/relay}"
port="${LAA_RELAY_PORT:-9120}"
https_port="${LAA_RELAY_HTTPS_PORT:-9443}"
public_url="${LAA_RELAY_PUBLIC_URL:-https://mac-mini.tailc9b8e7.ts.net:9443}"
runner="$repo/scripts/laa/relay-run.sh"
tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

fail() { echo "error: $*" >&2; exit 1; }

health() {
  curl -fsS --max-time 5 "http://127.0.0.1:$port/healthz" 2>/dev/null
}

case "$action" in
  install)
    command -v node >/dev/null || fail "node is missing (the relay needs 22 or newer)"
    [ -d "$source_dir/src" ] || fail "no relay source at $source_dir (is the conduit_push plugin installed?)"
    [ -x "$runner" ] || fail "$runner is not executable"
    [ -x "$tailscale" ] || fail "the Tailscale app is missing at $tailscale"

    echo "Installing the relay from $source_dir..."
    mkdir -p "$install_dir/app" "$install_dir/data"
    chmod 700 "$install_dir"
    rm -rf "$install_dir/app/src"
    cp -R "$source_dir/src" "$install_dir/app/src"
    cp "$source_dir/package.json" "$install_dir/app/package.json"
    node --check "$install_dir/app/src/server.mjs" || fail "the copied relay does not parse"

    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$runner</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>LAA_RELAY_HOME</key>
        <string>$install_dir</string>
        <key>LAA_RELAY_PORT</key>
        <string>$port</string>
        <key>LAA_RELAY_PUBLIC_URL</key>
        <string>$public_url</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$install_dir/relay.log</string>
    <key>StandardErrorPath</key>
    <string>$install_dir/relay.log</string>
</dict>
</plist>
PLIST
    plutil -lint "$plist" >/dev/null || fail "the launch agent did not parse"

    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist" || fail "launchctl bootstrap failed"
    echo "Started $label."

    # The tailnet address, one hop in front of the loopback port.
    "$tailscale" serve --bg --https="$https_port" "http://127.0.0.1:$port" >/dev/null \
      || fail "tailscale serve --https=$https_port failed"
    echo "Published at $public_url (tailnet only)."

    for _ in $(seq 1 20); do
      health >/dev/null && break
      sleep 1
    done
    health >/dev/null || {
      echo "the relay did not answer on 127.0.0.1:$port; its log:" >&2
      tail -n 20 "$install_dir/relay.log" >&2 || true
      fail "the relay did not start"
    }
    echo "Healthy: $(health)"
    ;;

  status)
    echo "launch agent:"
    launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -E "^\s+(state|pid|last exit code) " | sed 's/^ */  /' \
      || echo "  not loaded"
    echo "relay:"
    if body=$(health); then echo "  healthy on 127.0.0.1:$port: $body"; else echo "  no answer on 127.0.0.1:$port"; fi
    echo "tailnet:"
    "$tailscale" serve status 2>/dev/null | grep -A2 ":$https_port" | sed 's/^/  /' || echo "  not published"
    echo "log tail:"
    tail -n 5 "$install_dir/relay.log" 2>/dev/null | sed 's/^/  /' || true
    ;;

  uninstall)
    echo "Stopping the relay..."
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$plist"
    "$tailscale" serve --https="$https_port" off >/dev/null 2>&1 || true
    rm -rf "$install_dir"
    echo "Removed $label, its data and the tailnet address. The plugin's copy of"
    echo "the relay and the eight profiles' pairings were never touched."
    ;;

  *)
    fail "usage: scripts/laa/relay-install.sh [install|status|uninstall]"
    ;;
esac
