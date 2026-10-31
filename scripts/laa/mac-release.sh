#!/bin/bash
# Developer ID distribution: signed archive, Developer ID export, notarized app and DMG.
# Run with: /Users/laa/.config/laa/op-run-batch.sh /Users/laa/.config/laa/mac-release.env.tpl scripts/laa/mac-release.sh
# The template supplies ASC_KEY, ASC_KEY_ID, ASC_ISSUER_ID and the Developer ID
# PKCS#12 as LAA_DEVID_P12_B64 with LAA_DEVID_P12_PASSWORD.
set -euo pipefail
set +x
cd "$(dirname "$0")/../.."
repo="$PWD"
archive_only=0
if [ "${1:-}" = --archive-only ] && [ "$#" -eq 1 ]; then
    archive_only=1
elif [ "$#" -ne 0 ]; then
    printf 'usage: %s [--archive-only]\n' "$0" >&2
    exit 2
fi
if [ "$archive_only" -eq 0 ] && [ "${LAA_MAC_KEYCHAIN_ACTIVE:-}" != 1 ]; then
    exec /usr/bin/python3 "$repo/scripts/laa/mac-signing-keychain.py" "$repo/scripts/laa/mac-release.sh" "$@"
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false GIT_CONFIG_GLOBAL=/dev/null
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
redact_signing_names() {
    /usr/bin/sed -E 's/(Apple Development|Apple Distribution|Developer ID Application|Developer ID Installer|iPhone Developer|iPhone Distribution|Mac Developer): [^(]*\(/\1: <redacted> (/g; s/[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}/<redacted-id>/g; s/[[:xdigit:]]{8}-[[:xdigit:]]{16}/<redacted-id>/g; s/[[:xdigit:]]{40,}/<redacted-id>/g'
}
command -v xcodegen >/dev/null || fail 'xcodegen is required'
command -v python3 >/dev/null || fail 'python3 is required'
team="${LAA_TEAM_ID:-PAW258GB42}"
[ "$team" = PAW258GB42 ] || fail 'LAA_TEAM_ID must be PAW258GB42'
build_number="${CURRENT_PROJECT_VERSION:-$(date -u +%y%m%d%H%M)}"
case "$build_number" in ''|*[!0-9]*) fail 'CURRENT_PROJECT_VERSION must contain digits only';; esac
work="$repo/build/laa/mac/$build_number"
mkdir -p "$repo/build/laa/mac"
mkdir "$work" 2>/dev/null || fail "build folder already exists or could not be created: $work"
key_path=""
key_root=""
local_spec=""
archive="$work/LAA.xcarchive"
dmg="$work/LAA-$build_number.dmg"
sha_file="$work/LAA-$build_number.sha256"
archive_complete=0
dmg_complete=0
sha_complete=0
cleanup() {
    local result=$? cleanup_failed=0
    trap - EXIT INT TERM
    [ -z "$key_root" ] || rm -rf "$key_root" || cleanup_failed=1
    [ -z "$local_spec" ] || rm -f "$local_spec" || cleanup_failed=1
    rm -rf "$work/DerivedData" "$work/WebRTC-local" "$work/dmg-root" "$work/export" "$work/app-certs" || cleanup_failed=1
    rm -f "$work/LAA.zip" "$work/profiles.json" "$work/ExportOptions.plist" || cleanup_failed=1
    [ "$archive_complete" -eq 1 ] || rm -rf "$archive" || cleanup_failed=1
    [ "$dmg_complete" -eq 1 ] || rm -f "$dmg" || cleanup_failed=1
    [ "$sha_complete" -eq 1 ] || rm -f "$sha_file" || cleanup_failed=1
    rmdir "$work" 2>/dev/null || true
    if [ "$cleanup_failed" -ne 0 ]; then
        printf 'error: failed to remove temporary release files\n' >&2
        result=1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
auth=()
if [ "$archive_only" -eq 0 ]; then
    [ -n "${ASC_KEY:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] || fail 'ASC_KEY, ASC_KEY_ID and ASC_ISSUER_ID are required'
    mkdir -p "$HOME/.config/laa/tmp-secrets"
    chmod 700 "$HOME/.config/laa/tmp-secrets"
    key_root="$(mktemp -d "$HOME/.config/laa/tmp-secrets/mac-auth.XXXXXX")"
    chmod 700 "$key_root"
    key_path="$key_root/AuthKey.p8"
    (umask 077; printf '%s\n' "$ASC_KEY" > "$key_path")
    unset ASC_KEY
    [ -s "$key_path" ] || fail 'the API key file is empty'
    auth=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration -authenticationKeyPath "$key_path" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
else
    unset ASC_KEY ASC_KEY_ID ASC_ISSUER_ID LAA_DEVID_P12_B64 LAA_DEVID_P12_PASSWORD
fi

# xcodegen resolves a spec's `type: folder` resources against the spec's own
# directory (not the include), so the WebRTC overlay stays at the repo root and
# names project-laa.yml without a path. Under build/ the resource paths shift.
spec=project-laa.yml
if [ -n "${LAA_WEBRTC_XCFRAMEWORK:-}" ]; then
    [ -f "$LAA_WEBRTC_XCFRAMEWORK/Info.plist" ] || fail 'LAA_WEBRTC_XCFRAMEWORK must name the pinned xcframework'
    package="$work/WebRTC-local"
    mkdir -p "$package"
    ln -s "$(cd "$LAA_WEBRTC_XCFRAMEWORK" && pwd)" "$package/WebRTC.xcframework"
    cat > "$package/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "WebRTC", platforms: [.iOS(.v17)], products: [.library(name: "WebRTC", targets: ["WebRTC"])], targets: [.binaryTarget(name: "WebRTC", path: "WebRTC.xcframework")])
SWIFT
    spec_candidate="$repo/project-laa-local-$build_number-$$.yml"
    [ ! -e "$spec_candidate" ] && [ ! -L "$spec_candidate" ] || fail 'temporary project spec already exists'
    local_spec="$spec_candidate"
    spec="$local_spec"
    cat > "$local_spec" <<YAML
include:
  - path: project-laa.yml
packages:REPLACE:
  WebRTC:
    path: $package
YAML
fi
xcodegen generate --spec "$spec" --project "$repo" >/dev/null
if [ -n "$local_spec" ]; then
    rm -f "$local_spec"
    local_spec=""
fi
signing=()
[ "$archive_only" -eq 1 ] && signing=(CODE_SIGNING_ALLOWED=NO)
printf 'Archiving universal Mac Catalyst build %s...\n' "$build_number"
if ! xcodebuild archive -hideShellScriptEnvironment -project Conduit.xcodeproj -scheme Conduit -configuration Release \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' -archivePath "$archive" -derivedDataPath "$work/DerivedData" \
    -jobs 4 -packageAuthorizationProvider netrc ${auth[@]+"${auth[@]}"} DEVELOPMENT_TEAM="$team" \
    CURRENT_PROJECT_VERSION="$build_number" 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    ${signing[@]+"${signing[@]}"} 2>&1 | redact_signing_names > "$work/archive.log"; then
    fail "archive failed; see $work/archive.log"
fi
[ -d "$archive" ] || fail 'archive did not produce an xcarchive'
archive_complete=1
if [ "$archive_only" -eq 1 ]; then
    app="$archive/Products/Applications/Conduit.app"
    [ -d "$app" ] || app="$archive/Products/Applications/LAA.app"
    [ -d "$app" ] || fail 'archive did not produce LAA.app or Conduit.app'
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
    for architecture in arm64 x86_64; do
        /usr/bin/lipo -verify_arch "$architecture" "$app/Contents/MacOS/$executable" || fail 'application is not universal'
    done
    printf 'Archive: %s\n' "$archive"
    exit 0
fi

# Manual Developer ID export: automatic signing with the API key goes to Apple's
# cloud-managed certificate and fails with "Cloud signing permission error".
# The identity comes from the temporary keychain; the profiles must name the
# same certificate, so read its serial from that keychain (never hardcode it).
certificate_serial() {
    /usr/bin/security find-certificate -c "Developer ID Application" -p "$1" 2>/dev/null \
        | /usr/bin/openssl x509 -noout -serial 2>/dev/null \
        | /usr/bin/sed -n 's/^serial=//p' \
        | /usr/bin/head -n 1 || true
}
keychain_list="$(/usr/bin/security list-keychains -d user 2>/dev/null | /usr/bin/sed -n 's/^[[:space:]]*"\(.*\)"$/\1/p')"
serial=""
while IFS= read -r keychain; do
    [ -n "$keychain" ] || continue
    serial="$(certificate_serial "$keychain")"
    [ -z "$serial" ] || break
done <<< "$keychain_list"
[ -n "$serial" ] || fail 'no Developer ID Application certificate in the keychain search list'
profile_json="$work/profiles.json"
ASC_KEY_PATH="$key_path" ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" \
    /usr/bin/python3 "$repo/scripts/laa/mac-profiles.py" "$profile_json" --serial "$serial" \
    || fail 'could not prepare the Developer ID provisioning profiles'
/usr/bin/python3 - "$profile_json" "$work/ExportOptions.plist" "$team" <<'PY' || fail 'could not write ExportOptions.plist'
import json, plistlib, sys
profiles = json.load(open(sys.argv[1], encoding="utf-8"))
plistlib.dump({
    "method": "developer-id",
    "destination": "export",
    "teamID": sys.argv[3],
    "signingStyle": "manual",
    "signingCertificate": "Developer ID Application",
    "provisioningProfiles": {bundle: entry["uuid"] for bundle, entry in profiles.items()},
    "manageAppVersionAndBuildNumber": False,
}, open(sys.argv[2], "wb"))
PY
printf 'Exporting Developer ID application...\n'
if ! xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/export" \
    -exportOptionsPlist "$work/ExportOptions.plist" 2>&1 | redact_signing_names > "$work/export.log"; then
    fail "export failed; see $work/export.log"
fi
app="$work/export/LAA.app"
[ -d "$app" ] || app="$work/export/Conduit.app"
[ -d "$app" ] || fail 'export did not produce LAA.app or Conduit.app'
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
for architecture in arm64 x86_64; do
    /usr/bin/lipo -verify_arch "$architecture" "$app/Contents/MacOS/$executable" || fail 'application is not universal'
done
ditto -c -k --keepParent "$app" "$work/LAA.zip"
notarize() {
    local input="$1" result="$2"
    /usr/bin/xcrun notarytool submit "$input" --key "$key_path" --key-id "$ASC_KEY_ID" \
        --issuer "$ASC_ISSUER_ID" --wait --output-format json > "$result" || fail "notary submission failed; see $result"
    [ "$(/usr/bin/plutil -extract status raw -o - "$result")" = Accepted ] || fail "notarization was not accepted; see $result"
}
printf 'Notarizing and stapling application...\n'
notarize "$work/LAA.zip" "$work/app-notary.json"
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"
mv "$app" "$work/LAA.app"
app="$work/LAA.app"
if ! /usr/sbin/spctl -a -vv "$app" 2>&1 | /usr/bin/sed -n '/^source=/p'; then
    fail 'Gatekeeper rejected the application'
fi
stage="$work/dmg-root"
mkdir -p "$stage"
ditto "$app" "$stage/LAA.app"
ln -s /Applications "$stage/Applications"
/usr/bin/hdiutil create -volname LAA -srcfolder "$stage" -format UDZO "$dmg" >/dev/null
# Certificate 0 is the app's leaf certificate. Its SHA-1 selects exactly the
# same signing identity even when other certificates share its common name.
mkdir "$work/app-certs"
/usr/bin/codesign -d --extract-certificates="$work/app-certs/cert" "$app" >/dev/null 2>&1 \
    || fail 'could not read the exported application certificate'
[ -f "$work/app-certs/cert0" ] || fail 'exported application has no signing certificate'
identity="$(/usr/bin/openssl x509 -inform DER -in "$work/app-certs/cert0" -noout -fingerprint -sha1 2>/dev/null \
    | /usr/bin/sed -E 's/^[^=]*=//; s/://g')" || fail 'could not fingerprint the application certificate'
[ "${#identity}" -eq 40 ] || fail 'invalid application certificate fingerprint'
case "$identity" in *[![:xdigit:]]*) fail 'invalid application certificate fingerprint';; esac
if ! /usr/bin/codesign --force --timestamp --sign "$identity" "$dmg" 2>&1 | redact_signing_names; then
    fail 'could not sign the disk image'
fi
printf 'Notarizing and stapling disk image...\n'
notarize "$dmg" "$work/dmg-notary.json"
/usr/bin/xcrun stapler staple "$dmg"
/usr/bin/xcrun stapler validate "$dmg"
if ! /usr/sbin/spctl -a -vv --type open --context context:primary-signature "$dmg" 2>&1 | /usr/bin/sed -n '/^source=/p'; then
    fail 'Gatekeeper rejected the disk image'
fi
dmg_complete=1
printf 'DMG: %s\n' "$dmg"
/usr/bin/shasum -a 256 "$dmg" | /usr/bin/tee "$sha_file"
sha_complete=1
