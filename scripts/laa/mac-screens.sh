#!/bin/bash
# Photograph the LAA Mac window at the desktop sizes, without touching the
# installed app, its container, its Keychain or its pairing.
#
#   scripts/laa/mac-screens.sh [--owner shell] [--out DIR] [--fixture work]
#                              [--address URL] [--sections chats,work,...]
#                              [--sizes 900x600,1280x820,1680x1050]
#                              [--schemes light,dark] [--skip-build] [--self-render]
#                              [--app-args "-flag value"] [--app-env "K=V K2=V2"]
#
# --app-args adds launch arguments, --app-env adds environment variables. The
# Chat split needs a dashboard and an open conversation, which the DEBUG
# fixtures below supply without a real Hermes:
#
#   scripts/laa/mac-screens.sh --owner chat --sections chats \
#     --sizes 1280x820,1680x1050 --app-env "CONDUIT_UITEST=1" \
#     --app-args "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD https://conduit-ui-test.invalid
#                 -CONDUIT_UI_TEST_PROFILES work,staging
#                 -CONDUIT_UI_TEST_WIDGET_URL conduit://widget/v1/resume?..."
#
# The link is the same one ConduitUITests/LAAShellNavigationUITests uses; it
# opens a session that does not exist anywhere, so nothing is sent and no
# real Hermes or personal data is read.
#
# The build is a local Debug copy with its own bundle id (com.laa-inc.laa.macdev
# and .macdev.<suffix> for its extensions), ad-hoc signed, and with the app
# group and push entitlements removed: those need the team's provisioning, and
# a request the machine can't satisfy stops the app from launching at all. The
# spec copy (project-macdev.yml) and its DerivedData are made here and removed
# on exit; neither is committed, and the release signing settings in
# project-laa.yml and scripts/laa/mac-release.sh are not touched.
#
# The window sizes its content from a DEBUG launch argument (-laa-mac-window),
# and
# the section from -laa-mac-section, so no window automation is needed: the
# captures are the same every run. Each shot is a window capture
# (screencapture -l), so the desktop behind it never appears. --self-render
# has the window draw itself instead (DEBUG -laa-mac-snapshot), for a session
# without the screen-recording permission screencapture needs; it shows the
# app's content without the title bar.
#
# Sections whose screens need a Bridge fixture: pass --fixture <name> to start
# scripts/laa/<name>-ui-fixture.mjs and point the app at it with --address.
# Pairing that fixture needs the one-time code the UI tests type in, so an
# unpaired window (what this script captures by default) shows each section's
# own unpaired state instead of pretending to have data.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1

OWNER=shell
OUT=/Users/laa/work/laa-mac-redesign-20261103/shots
FIXTURE=""
ADDRESS=""
SECTIONS=chats,work,today,brain,studio,drive,usage
SIZES=900x600,1280x820,1680x1050
SCHEMES=light,dark
APP_ARGS=""
APP_ENV=""
SKIP_BUILD=0
SELF_RENDER=0
DEV_ID=com.laa-inc.laa.macdev
DEV_NAME="LAA"
DERIVED="$ROOT/.deriveddata-macdev"
SPEC="$ROOT/project-macdev.yml"
APP=""
FIXTURE_PID=""
APP_PID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --owner) OWNER=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --fixture) FIXTURE=$2; shift 2 ;;
    --address) ADDRESS=$2; shift 2 ;;
    --sections) SECTIONS=$2; shift 2 ;;
    --sizes) SIZES=$2; shift 2 ;;
    --schemes) SCHEMES=$2; shift 2 ;;
    --app-args) APP_ARGS=$2; shift 2 ;;
    --app-env) APP_ENV=$2; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --self-render) SELF_RENDER=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
  [ -n "$FIXTURE_PID" ] && kill "$FIXTURE_PID" 2>/dev/null
  rm -f "$SPEC"
  exit "${1:-0}"
}
trap 'cleanup 130' INT TERM

# The dev app's window: its CGWindowID and its size, matched by the pid this
# script launched. Bundle id alone is not enough: another worktree may be
# running the same dev build at the same time.
window_info() {
  local helper="$DERIVED/window-id"
  if [ ! -x "$helper" ]; then
    mkdir -p "$DERIVED"
    cat > "$DERIVED/window-id.swift" <<'SWIFT'
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else { exit(1) }
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                         kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
          (window[kCGWindowLayer as String] as? Int) == 0,
          let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double,
          width > 300, height > 200 else { continue }
    print("\(number) \(Int(width)) \(Int(height))")
    exit(0)
}
exit(1)
SWIFT
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcrun swiftc -O -o "$helper" "$DERIVED/window-id.swift" >/dev/null 2>&1 || return 1
  fi
  "$helper" "$1"
}

# The dev spec: same project, another identity, no entitlements the machine
# can't satisfy.
write_spec() {
  # Entitlements become empty rather than deleted: project.yml still names the
  # iOS entitlements for the same targets, and an empty value here is what
  # overrides it. Without that the build demands a provisioning profile for
  # app groups and push and never reaches a launch.
  sed -e "s/com\.laa-inc\.laa/com.laa-inc.laa.macdev/g" \
      -e 's/^\( *\)"CODE_SIGN_ENTITLEMENTS\[sdk=macosx\*\]":.*/\1"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": ""/' \
      -e 's/^\( *\)CODE_SIGN_ENTITLEMENTS:.*/\1CODE_SIGN_ENTITLEMENTS: ""/' \
      -e '/REGISTER_APP_GROUPS/d' \
      -e '/ENABLE_HARDENED_RUNTIME/d' \
      -e 's/^\( *\)DEVELOPMENT_TEAM: PAW258GB42/\1DEVELOPMENT_TEAM: ""/' \
      project-laa.yml > "$SPEC" || return 1
  grep -q "com.laa-inc.laa.macdev" "$SPEC" || return 1
  # No entitlement file may survive: a profile would be required again.
  ! grep -qE 'CODE_SIGN_ENTITLEMENTS: [^"]' "$SPEC" || return 1
  ! grep -q REGISTER_APP_GROUPS "$SPEC" || return 1
  return 0
}

build() {
  mkdir -p "$DERIVED"
  write_spec || { echo "could not write $SPEC" >&2; exit 1; }
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate --spec "$SPEC" >/dev/null || exit 1
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Users/laa/hq/harness/build-slot.sh \
    xcodebuild build -project Conduit.xcodeproj -scheme Conduit -configuration Debug \
      -destination 'platform=macOS,variant=Mac Catalyst' \
      -derivedDataPath "$DERIVED" -jobs 4 \
      CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
      DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
      CONDUIT_DISPLAY_NAME="$DEV_NAME" >"$DERIVED/build.log" 2>&1
  local status=$?
  if [ $status -ne 0 ]; then
    echo "build failed; see $DERIVED/build.log" >&2
    grep -m5 "error:" "$DERIVED/build.log" >&2
    exit 1
  fi
  APP="$DERIVED/Build/Products/Debug-maccatalyst/Conduit.app"
  [ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
  # The build is only for these shots: it is this script's own bundle id.
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null \
    | grep -q macdev || { echo "unexpected bundle id in $APP" >&2; exit 1; }
}

launch() {
  local section=$1 scheme=$2 size=$3 file=$4
  local args=(-laa-mac-section "$section" -laa-mac-window "$size"
              -conduit.themePreference "$scheme")
  [ "$SELF_RENDER" = 1 ] && args+=(-laa-mac-snapshot "$file")
  [ -n "$ADDRESS" ] && export LAA_BRIDGE_DEFAULT_ADDRESS="$ADDRESS"
  local extra=()
  [ -n "$APP_ARGS" ] && read -r -a extra <<< "$APP_ARGS"
  local pair
  for pair in $APP_ENV; do export "${pair?}"; done
  # A dev window is a fresh process every shot: no window state carries over
  # from the previous size or scheme. Its home is a folder of its own: the dev
  # build has no sandbox, so the fixtures' file reads would otherwise reach the
  # real Documents folder and wait on the system's permission prompt.
  mkdir -p "$DERIVED/home"
  CFFIXED_USER_HOME="$DERIVED/home" \
    "$APP/Contents/MacOS/Conduit" "${args[@]}" ${extra[@]+"${extra[@]}"} >"$DERIVED/app.log" 2>&1 &
  APP_PID=$!
}

stop_app() {
  [ -n "$APP_PID" ] || return 0
  kill "$APP_PID" 2>/dev/null
  for _ in $(seq 1 40); do
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 0.25
  done
  kill -9 "$APP_PID" 2>/dev/null
  APP_PID=""
  sleep 1
}

mkdir -p "$OUT/$OWNER" || exit 1
if [ "$SKIP_BUILD" = 1 ] && [ -d "$DERIVED/Build/Products/Debug-maccatalyst/Conduit.app" ]; then
  APP="$DERIVED/Build/Products/Debug-maccatalyst/Conduit.app"
else
  build
fi

if [ -n "$FIXTURE" ]; then
  node "$ROOT/scripts/laa/$FIXTURE-ui-fixture.mjs" >"$DERIVED/fixture.log" 2>&1 &
  FIXTURE_PID=$!
  sleep 2
fi

IFS=',' read -r -a section_list <<< "$SECTIONS"
IFS=',' read -r -a size_list <<< "$SIZES"
IFS=',' read -r -a scheme_list <<< "$SCHEMES"

shots=0
for section in "${section_list[@]}"; do
  for scheme in "${scheme_list[@]}"; do
    for size in "${size_list[@]}"; do
      file="$OUT/$OWNER/$section-${size}-$scheme.png"
      rm -f "$file"
      launch "$section" "$scheme" "$size" "$file"
      # Wait for the window, then for it to take the requested size: the
      # geometry request lands a moment after the window appears.
      want_w=${size%x*}
      want_h=${size#*x}
      id=""
      for _ in $(seq 1 120); do
        info=$(window_info "$APP_PID")
        if [ -n "$info" ]; then
          read -r wid ww wh <<< "$info"
          # The geometry request sets the content size, so the window frame is
          # that plus the title bar. Anything in that range is the window asked
          # for, at the requested content size.
          if [ "$ww" -ge "$((want_w - 2))" ] && [ "$ww" -le "$((want_w + 2))" ] \
             && [ "$wh" -ge "$want_h" ] && [ "$wh" -le "$((want_h + 40))" ]; then
            id=$wid; break
          fi
        fi
        sleep 0.5
      done
      if [ -z "$id" ]; then
        echo "no ${want_w}x${want_h} window for $section $scheme" >&2
        stop_app
        continue
      fi
      if [ "$SELF_RENDER" = 1 ]; then
        # The window writes the file a few seconds after it settles.
        for _ in $(seq 1 60); do [ -s "$file" ] && break; sleep 0.5; done
      else
        screencapture -x -o -l "$id" "$file"
      fi
      if [ -s "$file" ]; then
        shots=$((shots + 1))
        echo "$file"
      else
        echo "capture failed: $file" >&2
      fi
      stop_app
    done
  done
done

stop_app
[ -n "$FIXTURE_PID" ] && kill "$FIXTURE_PID" 2>/dev/null
rm -f "$SPEC"
echo "$shots shots in $OUT/$OWNER"
