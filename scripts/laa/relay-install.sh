#!/bin/bash
# Installs the LAA push relay: the service behind com.laa-inc.laa's alerts and
# VoIP rings. It runs the relay this Mac already has — the one shipped with
# the conduit_push plugin — under its own launchd job and its own APNs key, so
# the App Store app's relay (push.milim.dev) and the eight profiles paired to
# it are untouched.
#
#   scripts/laa/relay-install.sh            install and start
#   scripts/laa/relay-install.sh status     what is running
#   scripts/laa/relay-install.sh uninstall  stop and remove the relay AND its
#                                           data (the phone registers again)
#   scripts/laa/relay-install.sh rollback   undo the D-35 rename only: stop the
#                                           job, put the data folder back under
#                                           its old name, and leave it for the
#                                           older checkout's relay-install.sh
#
# The relay is bound to 127.0.0.1:9120 and published on the tailnet only, at
# the privately configured LAA_RELAY_PUBLIC_URL, also embedded at release.
# Both the phone and this Mac must be on the tailnet.
#
# One relay serves one app bundle: APNS_TOPIC is com.laa-inc.laa. A Hermes
# profile pairs with exactly one relay, so the LAA app is paired by a profile
# that pushes here — see docs/LAA_BUILD.md.
set -euo pipefail
set +x

cd "$(dirname "$0")/../.."
repo="$PWD"
action="${1:-install}"
label="com.laa.hortensia-relay"
plist="$HOME/Library/LaunchAgents/$label.plist"
install_dir="${LAA_RELAY_HOME:-$HOME/.local/share/laa-hortensia-relay}"
# D-35: the job and its folder were com.laa.conduit-relay-laa and
# laa-conduit-relay-laa. install moves that folder (data/relay.json holds the
# phone's push registration) and leaves a link at the old path, so an older
# install script or job still finds the same data. The old job is stopped for
# the move, started again if this install fails, and its file is removed only
# once the new job answers. Every step can be run again after a failure.
legacy_label="com.laa.conduit-relay-laa"
legacy_plist="$HOME/Library/LaunchAgents/$legacy_label.plist"
legacy_dir="$HOME/.local/share/laa-conduit-relay-laa"
source_dir="${LAA_RELAY_SOURCE:-$HOME/.hermes/plugins/conduit_push/relay}"
port="${LAA_RELAY_PORT:-9120}"
https_port="${LAA_RELAY_HTTPS_PORT:-9443}"
public_url="${LAA_RELAY_PUBLIC_URL:-}"
runner="$repo/scripts/laa/relay-run.sh"
tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

fail() { echo "error: $*" >&2; exit 1; }

health() {
  curl -fsS --max-time 5 "http://127.0.0.1:$port/healthz" 2>/dev/null
}

domain="gui/$(id -u)"
loaded() { launchctl print "$domain/$1" >/dev/null 2>&1; }
# bootout returns before the job is gone; a bootstrap straight after it fails.
stop_job() {
  loaded "$1" || return 0
  launchctl bootout "$domain/$1" 2>/dev/null || true
  for _ in $(seq 1 20); do loaded "$1" || return 0; sleep 0.5; done
  return 1
}

# Set while the old job is stopped and the new one is not yet proven.
restore_legacy=0
on_exit() {
  status=$?
  [ "$restore_legacy" = 1 ] || exit "$status"
  restore_legacy=0
  echo "The install did not finish; starting $legacy_label again..." >&2
  stop_job "$label" || true
  rm -f "$plist"
  # Its LAA_RELAY_HOME is the old path, now a link to the moved folder.
  if [ -f "$legacy_plist" ] && launchctl bootstrap "$domain" "$legacy_plist"; then
    echo "$legacy_label is running on the same data. Fix the error and run install again." >&2
  else
    echo "error: $legacy_label did not start. The data is safe in $install_dir; run install again." >&2
  fi
  exit "$status"
}
trap on_exit EXIT

case "$action" in
  install)
    [ -n "$public_url" ] || fail 'set LAA_RELAY_PUBLIC_URL in the private install environment'
    command -v node >/dev/null || fail "node is missing (the relay needs 22 or newer)"
    [ -d "$source_dir/src" ] || fail "no relay source at $source_dir (is the conduit_push plugin installed?)"
    [ -x "$runner" ] || fail "$runner is not executable"
    [ -x "$tailscale" ] || fail "the Tailscale app is missing at $tailscale"

    # Both jobs bind the same port and write the same relay.json.
    if loaded "$legacy_label"; then
      [ -f "$legacy_plist" ] || fail "$legacy_label is loaded but $legacy_plist is missing; it could not be restored"
      echo "Stopping $legacy_label..."
      restore_legacy=1
      stop_job "$legacy_label" || fail "$legacy_label did not stop"
    fi
    if [ -z "${LAA_RELAY_HOME:-}" ] && [ -d "$legacy_dir" ] && [ ! -L "$legacy_dir" ]; then
      if [ ! -e "$install_dir" ] && [ ! -L "$install_dir" ]; then
        echo "Moving $legacy_dir to $install_dir (keeps the push registration)..."
        mv "$legacy_dir" "$install_dir" || fail "could not move $legacy_dir; nothing was changed"
      elif [ -f "$legacy_dir/data/relay.json" ] && [ ! -e "$install_dir/data/relay.json" ]; then
        # Both folders exist: an earlier run made the new one without the data.
        echo "Copying the push registration from $legacy_dir..."
        mkdir -p "$install_dir/data"
        cp -p "$legacy_dir/data/relay.json" "$install_dir/data/relay.json.migrating" \
          && mv "$install_dir/data/relay.json.migrating" "$install_dir/data/relay.json" \
          || fail "could not copy $legacy_dir/data/relay.json"
      else
        echo "Leaving $legacy_dir as it is; $install_dir already has its own data."
      fi
    fi
    # The old path keeps working for an older script or job.
    if [ -z "${LAA_RELAY_HOME:-}" ] && [ ! -e "$legacy_dir" ] && [ ! -L "$legacy_dir" ] && [ -d "$install_dir" ]; then
      ln -s "$install_dir" "$legacy_dir" || echo "warning: could not link $legacy_dir to $install_dir" >&2
    fi

    echo "Installing the relay from $source_dir..."
    mkdir -p "$install_dir/app" "$install_dir/data"
    chmod 700 "$install_dir"
    stage="$(mktemp -d "$install_dir/.relay.XXXXXX")"
    trap 'rm -rf "$stage"' EXIT
    cp -R "$source_dir/src" "$stage/src"
    patch -f -s -F 0 -p0 -d "$stage/src" < "$repo/scripts/laa/relay-decision-badge.patch" || fail 'relay source does not match the badge overlay'
    cp "$repo/scripts/laa/relay-decision-badge.mjs" "$stage/src/"
    node --check "$stage/src/server.mjs" || fail "the copied relay does not parse"
    rm -rf "$install_dir/app/src"
    mv "$stage/src" "$install_dir/app/src"
    cp "$source_dir/package.json" "$install_dir/app/package.json"

    stop_job "$label" || fail "$label did not stop"
    # With both jobs stopped, an answer here is some other relay; its health
    # reply would be taken for the new job's.
    ! health >/dev/null || fail "something else still answers on 127.0.0.1:$port"
    cat > "$plist.new" <<PLIST
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
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$install_dir/relay.log</string>
    <key>StandardErrorPath</key>
    <string>$install_dir/relay.log</string>
</dict>
</plist>
PLIST
    plutil -lint "$plist.new" >/dev/null || { rm -f "$plist.new"; fail "the launch agent did not parse"; }
    mv "$plist.new" "$plist"

    launchctl bootstrap "$domain" "$plist" || fail "launchctl bootstrap failed"
    echo "Started $label."

    # The tailnet address, one hop in front of the loopback port.
    "$tailscale" serve --bg --https="$https_port" "http://127.0.0.1:$port" >/dev/null \
      || fail "tailscale serve --https=$https_port failed"
    echo 'Published on the tailnet only.'

    for _ in $(seq 1 20); do
      health >/dev/null && break
      sleep 1
    done
    health >/dev/null && loaded "$label" || {
      echo "the relay did not answer on 127.0.0.1:$port; its log:" >&2
      tail -n 20 "$install_dir/relay.log" >&2 || true
      fail "the relay did not start"
    }
    echo "Healthy: $(health)"
    # Only now is the old job's file removed; left in place it would start at
    # the next login and fight the new job for the port.
    restore_legacy=0
    if [ -f "$legacy_plist" ]; then
      rm -f "$legacy_plist"
      echo "Retired $legacy_label."
    fi
    ;;

  status)
    echo "launch agent:"
    launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -E "^\s+(state|pid|last exit code) " | sed 's/^ */  /' \
      || echo "  not loaded"
    if loaded "$legacy_label" || [ -f "$legacy_plist" ]; then
      echo "  the old job $legacy_label is still installed; run install to finish the rename"
    fi
    echo "relay:"
    if body=$(health); then echo "  healthy on 127.0.0.1:$port: $body"; else echo "  no answer on 127.0.0.1:$port"; fi
    echo "tailnet:"
    "$tailscale" serve status 2>/dev/null | grep -A2 ":$https_port" | sed 's/^/  /' || echo "  not published"
    echo "log tail:"
    tail -n 5 "$install_dir/relay.log" 2>/dev/null | sed 's/^/  /' || true
    ;;

  uninstall)
    echo "Stopping the relay..."
    stop_job "$label" || true
    stop_job "$legacy_label" || true
    rm -f "$plist" "$legacy_plist"
    "$tailscale" serve --https="$https_port" off >/dev/null 2>&1 || true
    rm -rf "$install_dir"
    # Only the link install left; a real folder under the old name is not this script's to delete.
    if [ -L "$legacy_dir" ]; then rm -f "$legacy_dir"; fi
    if [ -d "$legacy_dir" ]; then echo "Left $legacy_dir (the folder from before the rename) in place."; fi
    echo "Removed $label, its data and the tailnet address. The plugin's copy of"
    echo "the relay and the eight profiles' pairings were never touched."
    ;;

  rollback)
    [ -z "${LAA_RELAY_HOME:-}" ] || fail "rollback moves the default folders; unset LAA_RELAY_HOME"
    echo "Stopping $label..."
    stop_job "$label" || fail "$label did not stop"
    rm -f "$plist"
    if [ -L "$legacy_dir" ]; then rm -f "$legacy_dir"; fi
    if [ -d "$install_dir" ] && [ ! -L "$install_dir" ]; then
      [ ! -e "$legacy_dir" ] || fail "$legacy_dir already exists; the data stays in $install_dir"
      mv "$install_dir" "$legacy_dir" || fail "could not move $install_dir back"
    fi
    echo "The data is at $legacy_dir and no relay job is running."
    echo "Now run relay-install.sh from the checkout of the older build."
    ;;

  *)
    fail "usage: scripts/laa/relay-install.sh [install|status|uninstall|rollback]"
    ;;
esac
