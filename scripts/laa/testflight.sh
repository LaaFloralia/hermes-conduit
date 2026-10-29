#!/bin/bash
# Archives the LAA build (project-laa.yml), uploads it to App Store Connect and
# waits until TestFlight offers it to the LAA Internal group. This is the
# fork's TestFlight path; scripts/laa/install-on-iphone.sh is the separate
# cable-install path for a free Apple ID.
#
#   /Users/laa/.config/laa/op-run-batch.sh /Users/laa/.config/laa/asc.env.tpl \
#     scripts/laa/testflight.sh
#
# The App Store Connect key reaches this script as ASC_KEY, ASC_KEY_ID and
# ASC_ISSUER_ID from 1Password (the final wait for the build needs it either
# way). xcodebuild is given it — as a 0600 file under ~/.config/laa/tmp-secrets,
# the only form it accepts, removed however the script exits — only when Xcode
# has no Apple ID for the team; with one, the account signs (see step 2). Nothing
# prints, logs or passes the key as an argument.
#
# Environment (all optional):
#   CURRENT_PROJECT_VERSION  build number; default is the UTC time (YYMMDDHHMM)
#   MARKETING_VERSION        the TestFlight version; default from project.yml
#   CONDUIT_DISPLAY_NAME     home screen name; default LAA
#   LAA_TEAM_ID              default PAW258GB42
#   LAA_APP_ID               App Store Connect app; default 6828276003 (LAA)
#   LAA_BETA_GROUP_ID        default 90513640-2a93-493f-952b-cf431090174f (LAA Internal)
#   LAA_EXPORT_DESTINATION   upload (default) or export, which writes the .ipa
#                            under build/laa/export and uploads nothing
#   ASC_WAIT_SECONDS         how long to wait for the build to be VALID (2700)
set -euo pipefail
set +x

cd "$(dirname "$0")/../.."
repo="$PWD"
work="$repo/build/laa"
team="${LAA_TEAM_ID:-PAW258GB42}"
app_id="${LAA_APP_ID:-6828276003}"
group_id="${LAA_BETA_GROUP_ID:-90513640-2a93-493f-952b-cf431090174f}"
destination="${LAA_EXPORT_DESTINATION:-upload}"
key_dir="$HOME/.config/laa/tmp-secrets"

fail() { echo "error: $*" >&2; exit 1; }

# 1. What this script cannot do without.
[ -n "${ASC_KEY:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] || fail \
  "ASC_KEY, ASC_KEY_ID and ASC_ISSUER_ID must be set. Run this through
  /Users/laa/.config/laa/op-run-batch.sh /Users/laa/.config/laa/asc.env.tpl"
case "$destination" in
  upload|export) ;;
  *) fail "LAA_EXPORT_DESTINATION must be upload or export, not '$destination'" ;;
esac

# xcode-select still points at the Command Line Tools, so name the developer
# directory instead of changing a machine-wide setting.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -version >/dev/null 2>&1 || fail \
  "no usable Xcode at $DEVELOPER_DIR (xcodebuild -version failed). Install Xcode and accept its license."
command -v xcodegen >/dev/null || fail "xcodegen is missing: brew install xcodegen"
command -v node >/dev/null || fail "node is missing: the App Store Connect calls in scripts/laa/asc.mjs need it"

# SwiftPM fetches the WebRTC package from a public repository, so nothing in
# this build needs a GitHub credential — and the login keychain must not be
# consulted: a git credential helper pops a password dialog the machine can't
# answer (2026-10-29). These make such a request fail instead of prompting.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/usr/bin/false
export SSH_ASKPASS=/usr/bin/false
export GIT_CONFIG_GLOBAL=/dev/null

mkdir -p "$work"
build_number="${CURRENT_PROJECT_VERSION:-$(date -u +%y%m%d%H%M)}"
case "$build_number" in
  ''|*[!0-9]*) fail "CURRENT_PROJECT_VERSION must be digits, not '$build_number'" ;;
esac

# 2. Which session signs this build.
#
# Xcode's automatic signing has to add the App Groups (and HealthKit) to the
# LAA App IDs the first time, and only an Apple ID added to Xcode may change an
# App ID. An App Store Connect API key can read the portal and make profiles —
# and that is what the profiles already fetched show: aps-environment set,
# application-groups empty — but a capability change is refused, which surfaces
# as "Authentication failed: Make sure a bearer token was provided…" and then
# as "Provisioning profile … doesn't support the group.com.laa-inc.laa.* App
# Group" (measured 2026-10-29: with the same key and entitlements the App IDs
# already carry, provisioning passes). So: use the Apple ID when Xcode has one
# for this team, and the key only when it doesn't.
with_account=no
if defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null | grep -q "$team"; then
  with_account=yes
fi

key_path=""
if [ "$with_account" = yes ]; then
  echo "Signing with the Apple ID Xcode has for team $team (it can add the App capabilities)"
else
  # 2b. The key, for as long as this script runs: the only form xcodebuild
  #     takes it in, removed however the script exits.
  mkdir -p "$key_dir"
  chmod 700 "$key_dir"
  key_root="$(mktemp -d "$key_dir/authkey.XXXXXX")"
  chmod 700 "$key_root"
  key_path="$key_root/AuthKey_${ASC_KEY_ID}.p8"
  (umask 077; printf '%s\n' "$ASC_KEY" > "$key_path")
  trap 'rm -rf "$key_root"' EXIT INT TERM
  [ -s "$key_path" ] || fail "the App Store Connect key file came out empty"
  echo "Signing with the App Store Connect API key $ASC_KEY_ID (no Apple ID in Xcode)"
fi

# 3. The project. Generated, never committed (build/ is ignored).
#
# LAA_WEBRTC_XCFRAMEWORK is the way past a SwiftPM binary-artifact download
# that never finishes (2026-10-29: on this Mac every archive stalled at
# "Checking out 153.0.0 of package 'WebRTC'" and no bytes arrived, while the
# same release zip downloaded in seconds with curl). Point it at an extracted
# WebRTC.xcframework from the release the manifest pins — release 153.0.0,
# sha256 3e3a8946f27510133e3feed04d05fa23505bbe366e977620503bfc7986c2b78f —
# and the project links that copy instead. Unset, SwiftPM resolves the
# package as usual, which is what CI does.
spec=project-laa.yml
if [ -n "${LAA_WEBRTC_XCFRAMEWORK:-}" ]; then
  [ -d "$LAA_WEBRTC_XCFRAMEWORK" ] || fail "LAA_WEBRTC_XCFRAMEWORK is not a directory: $LAA_WEBRTC_XCFRAMEWORK"
  [ -f "$LAA_WEBRTC_XCFRAMEWORK/Info.plist" ] || fail "$LAA_WEBRTC_XCFRAMEWORK is not an xcframework"
  package="$work/WebRTC-local"
  rm -rf "$package"
  mkdir -p "$package"
  ln -s "$(cd "$LAA_WEBRTC_XCFRAMEWORK" && pwd)" "$package/WebRTC.xcframework"
  cat > "$package/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
// The WebRTC release project.yml pins, as a package without a download.
import PackageDescription

let package = Package(
    name: "WebRTC",
    platforms: [.iOS(.v17)],
    products: [.library(name: "WebRTC", targets: ["WebRTC"])],
    targets: [.binaryTarget(name: "WebRTC", path: "WebRTC.xcframework")]
)
SWIFT
  spec="$work/project-laa-local.yml"
  cat > "$spec" <<YAML
# Generated by scripts/laa/testflight.sh: project-laa.yml with WebRTC on disk.
include:
  - path: ../../project-laa.yml
packages:REPLACE:
  WebRTC:
    path: $package
YAML
  echo "WebRTC: linking $LAA_WEBRTC_XCFRAMEWORK instead of SwiftPM's download"
fi
echo "Generating Conduit.xcodeproj from $(basename "$spec") (build $build_number)..."
# Written at the repository root whatever the spec's own place: source paths
# resolve against the file that declares them, and -project expects it here.
xcodegen generate --spec "$spec" --project "$repo" >/dev/null

# Resolve SwiftPM's package once, through the system git and the credential-free
# environment above: a private-repository prompt fails here, in the open, and
# the archive that follows finds the packages already checked out.
if [ -z "${LAA_WEBRTC_XCFRAMEWORK:-}" ]; then
  echo "Resolving Swift packages (no credentials consulted)..."
  if ! xcodebuild -resolvePackageDependencies \
      -project Conduit.xcodeproj \
      -scheme Conduit \
      -scmProvider system \
      -derivedDataPath "$work/DerivedData" > "$work/resolve.log" 2>&1; then
    grep -E "error:|could not|failed" "$work/resolve.log" | head -n 10 || true
    fail "Swift package resolution failed; see $work/resolve.log (nothing prompted for a password)"
  fi
fi

archive="$work/LAA.xcarchive"
rm -rf "$archive" "$work/export"
auth=(-allowProvisioningUpdates)
if [ "$with_account" = no ]; then
  auth+=(
    -authenticationKeyPath "$key_path"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi
# Passed only when set, so project.yml's values stand otherwise. macOS's bash
# 3.2 needs the +"${...}" guard to expand an empty array under `set -u`.
extra=()
[ -n "${MARKETING_VERSION:-}" ] && extra+=(MARKETING_VERSION="$MARKETING_VERSION")
[ -n "${CONDUIT_DISPLAY_NAME:-}" ] && extra+=(CONDUIT_DISPLAY_NAME="$CONDUIT_DISPLAY_NAME")

# 4. The archive. Automatic signing registers the LAA App IDs' capabilities
#    and makes the profiles the archive needs.
echo "Archiving Release for generic iOS..."
log="$work/archive.log"
if ! xcodebuild archive \
    -project Conduit.xcodeproj \
    -scheme Conduit \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -derivedDataPath "$work/DerivedData" \
    "${auth[@]}" \
    DEVELOPMENT_TEAM="$team" \
    CURRENT_PROJECT_VERSION="$build_number" \
    ${extra[@]+"${extra[@]}"} \
    > "$log" 2>&1; then
  grep -E "error:|BUILD FAILED|code signing|Provisioning" "$log" | head -n 40 || true
  fail "the archive failed; the whole log is $log"
fi
[ -d "$archive" ] || fail "xcodebuild reported success but left no $archive"
echo "Archived: $archive"
echo "  version $(plutil -extract ApplicationProperties.CFBundleShortVersionString raw -o - "$archive/Info.plist" 2>/dev/null || echo '?')" \
     "build $(plutil -extract ApplicationProperties.CFBundleVersion raw -o - "$archive/Info.plist" 2>/dev/null || echo '?')"

# 5. Export and upload. `app-store-connect` is the App Store Connect
#    destination; with `destination=upload` xcodebuild uploads the .ipa itself.
options="$work/ExportOptions.plist"
cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$destination</string>
    <key>teamID</key>
    <string>$team</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
PLIST
[ "$destination" = upload ] && echo "Exporting and uploading to App Store Connect..." \
  || echo "Exporting to $work/export (no upload)..."
export_log="$work/export.log"
if ! xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportPath "$work/export" \
    -exportOptionsPlist "$options" \
    "${auth[@]}" \
    > "$export_log" 2>&1; then
  grep -E "error:|Error|failed" "$export_log" | head -n 40 || true
  fail "the export failed; the whole log is $export_log"
fi
tail -n 3 "$export_log"

if [ "$destination" != upload ]; then
  echo
  echo "Built LAA $build_number without uploading. The .ipa is under $work/export;"
  echo "upload it with LAA_EXPORT_DESTINATION=upload $0"
  exit 0
fi

# 6. The upload is asynchronous: wait until App Store Connect has processed
#    the build and the group can install it.
echo "Waiting for App Store Connect to finish processing build $build_number..."
node scripts/laa/asc.mjs wait-build "$app_id" "$build_number" "$group_id"
echo
echo "LAA build $build_number is in TestFlight for the LAA Internal group."
echo "Install it on the iPhone from the TestFlight app."
