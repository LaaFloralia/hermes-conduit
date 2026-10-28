#!/bin/bash
# Builds the LAA fork (project-personal.yml) and installs it on your iPhone,
# beside the App Store Conduit.
#
# Once: install Xcode, sign in under Xcode > Settings > Accounts (a free
# Apple ID works; its builds expire after 7 days, so run this again weekly),
# connect the iPhone by cable and trust this Mac, and turn on Settings >
# Privacy & Security > Developer Mode on the iPhone. After the first
# install, trust the developer under Settings > General > VPN & Device
# Management.
#
# Usage: scripts/laa/install-on-iphone.sh
#   CONDUIT_TEAM_ID   your team ID, when Xcode has more than one
#   CONDUIT_DEVICE    the iPhone's UDID, when more than one is connected
#   CONDUIT_PERSONAL_NAME  the home screen name (default "Conduit LAA")
set -euo pipefail

cd "$(dirname "$0")/../.."
work="build/personal"
mkdir -p "$work"

fail() { echo "error: $*" >&2; exit 1; }

xcode=$(xcode-select -p 2>/dev/null || true)
case "$xcode" in
  *.app/Contents/Developer) ;;
  *) fail "Xcode isn't selected (xcode-select -p: ${xcode:-none}). Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app" ;;
esac

team="${CONDUIT_TEAM_ID:-}"
if [ -z "$team" ]; then
  # The teams of the accounts signed in to Xcode.
  teams=$(defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -I -c '
import plistlib, sys
try:
    prefs = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(0)
found = []
for key in ("IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"):
    for account_teams in (prefs.get(key) or {}).values():
        for team in account_teams or []:
            team_id = team.get("teamID")
            if team_id and team_id not in found:
                found.append(team_id)
print("\n".join(found))
')
  count=$(printf '%s' "$teams" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    fail "no team in Xcode. Sign in under Xcode > Settings > Accounts, or set CONDUIT_TEAM_ID."
  elif [ "$count" -gt 1 ]; then
    fail "Xcode has several teams ($(echo $teams)). Set CONDUIT_TEAM_ID to one of them."
  fi
  team="$teams"
fi

device="${CONDUIT_DEVICE:-}"
if [ -z "$device" ]; then
  xcrun devicectl list devices --json-output "$work/devices.json" >/dev/null 2>&1 \
    || fail "couldn't list devices (xcrun devicectl). Is the iPhone connected and trusted?"
  device=$(python3 -I - "$work/devices.json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
phones = [
    d for d in devices
    if d.get("hardwareProperties", {}).get("platform") == "iOS"
    and d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
    and d.get("connectionProperties", {}).get("pairingState") == "paired"
]
if len(phones) == 1:
    print(phones[0]["hardwareProperties"]["udid"])
else:
    for d in phones:
        print(d["hardwareProperties"]["udid"], d.get("deviceProperties", {}).get("name", ""), file=sys.stderr)
PY
)
  [ -n "$device" ] || fail "no single paired iPhone (see above). Connect one, or set CONDUIT_DEVICE to its UDID."
fi

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate --spec project-personal.yml

echo "Building for $device with team $team..."
xcodebuild build \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -configuration Release \
  -destination "id=$device" \
  -derivedDataPath "$work/DerivedData" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$team" \
  | tail -n 40

app="$work/DerivedData/Build/Products/Release-iphoneos/Conduit.app"
[ -d "$app" ] || fail "the build left no $app"

xcrun devicectl device install app --device "$device" "$app"
# A locked phone refuses the launch; the install still stands.
xcrun devicectl device process launch --device "$device" com.laa-inc.conduit >/dev/null 2>&1 \
  || echo "Installed. Unlock the iPhone and open ${CONDUIT_PERSONAL_NAME:-Conduit LAA}."
