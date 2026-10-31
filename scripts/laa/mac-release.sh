#!/bin/bash
# Developer ID distribution; run only with the team's App Store Connect key:
# /Users/laa/.config/laa/op-run-batch.sh /Users/laa/.config/laa/mac-release.env.tpl scripts/laa/mac-release.sh
# In addition to ASC_KEY, ASC_KEY_ID and ASC_ISSUER_ID, supply the Developer ID
# PKCS#12 and its password as LAA_DEVID_P12_B64 and LAA_DEVID_P12_PASSWORD.
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
command -v xcodegen >/dev/null || fail 'xcodegen is required'
team="${LAA_TEAM_ID:-PAW258GB42}"
build_number="${CURRENT_PROJECT_VERSION:-$(date -u +%y%m%d%H%M)}"
case "$build_number" in ''|*[!0-9]*) fail 'CURRENT_PROJECT_VERSION must contain digits only';; esac
work="$repo/build/laa/mac/$build_number"
[ ! -e "$work" ] || fail "build folder already exists: $work"
mkdir -p "$work"
auth=()
if [ "$archive_only" -eq 0 ]; then
    [ -n "${ASC_KEY:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] || fail 'ASC_KEY, ASC_KEY_ID and ASC_ISSUER_ID are required'
    mkdir -p "$HOME/.config/laa/tmp-secrets"
    chmod 700 "$HOME/.config/laa/tmp-secrets"
    key_root="$(mktemp -d "$HOME/.config/laa/tmp-secrets/mac-auth.XXXXXX")"
    cleanup() { rm -rf "$key_root"; }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    chmod 700 "$key_root"
    key_path="$key_root/AuthKey.p8"
    (umask 077; printf '%s\n' "$ASC_KEY" > "$key_path")
    unset ASC_KEY
    [ -s "$key_path" ] || fail 'the API key file is empty'
    auth=(-allowProvisioningUpdates -authenticationKeyPath "$key_path" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

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
    spec="$work/project-laa-local.yml"
    cat > "$spec" <<YAML
include:
  - path: ../../../../project-laa.yml
packages:REPLACE:
  WebRTC:
    path: $package
YAML
fi
xcodegen generate --spec "$spec" --project "$repo" >/dev/null
archive="$work/LAA.xcarchive"
printf 'Archiving universal Mac Catalyst build %s...\n' "$build_number"
if ! xcodebuild archive -hideShellScriptEnvironment -project Conduit.xcodeproj -scheme Conduit -configuration Release \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' -archivePath "$archive" -derivedDataPath "$work/DerivedData" \
    -jobs 4 -packageAuthorizationProvider netrc ${auth[@]+"${auth[@]}"} DEVELOPMENT_TEAM="$team" \
    CURRENT_PROJECT_VERSION="$build_number" 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- > "$work/archive.log" 2>&1; then
    fail "archive failed; see $work/archive.log"
fi
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
cat > "$work/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>destination</key><string>export</string>
<key>teamID</key><string>$team</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
printf 'Exporting Developer ID application...\n'
if ! xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/export" \
    -exportOptionsPlist "$work/ExportOptions.plist" "${auth[@]}" > "$work/export.log" 2>&1; then
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
/usr/sbin/spctl -a -vv "$app"
stage="$work/dmg-root"
mkdir -p "$stage"
ditto "$app" "$stage/LAA.app"
ln -s /Applications "$stage/Applications"
dmg="$work/LAA-$build_number.dmg"
/usr/bin/hdiutil create -volname LAA -srcfolder "$stage" -format UDZO "$dmg" >/dev/null
# The automatic export chooses the application's Developer ID. Sign the DMG
# with that same identity; never guess among the user's installed identities.
identity="$(/usr/bin/codesign -dvv "$app" 2>&1 | /usr/bin/sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | /usr/bin/head -n 1)"
[ -n "$identity" ] || fail 'exported application has no Developer ID Application signature'
/usr/bin/codesign --force --timestamp --sign "$identity" "$dmg"
printf 'Notarizing and stapling disk image...\n'
notarize "$dmg" "$work/dmg-notary.json"
/usr/bin/xcrun stapler staple "$dmg"
/usr/bin/xcrun stapler validate "$dmg"
/usr/sbin/spctl -a -vv --type open --context context:primary-signature "$dmg"
printf 'DMG: %s\n' "$dmg"
/usr/bin/shasum -a 256 "$dmg"
