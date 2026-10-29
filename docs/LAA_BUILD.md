# LAA build

The LAA fork ships its own app beside the App Store Conduit: display name
**LAA**, bundle IDs under `com.laa-inc.laa`, signed by the LAA team, delivered
through TestFlight to the LAA Internal group. The App Store app keeps its own
bundle IDs, App Group, entitlements and relay; nothing here changes it.

There is one path:

```sh
/Users/laa/.config/laa/op-run-batch.sh /Users/laa/.config/laa/asc.env.tpl \
  scripts/laa/testflight.sh
```

It generates `Conduit.xcodeproj` from `project-laa.yml`, archives Release for
generic iOS with automatic signing, exports with `method app-store-connect` and
`destination upload`, then waits on the App Store Connect API until the build
is VALID and the LAA Internal group can install it. Every build number is the
UTC time it started (`CURRENT_PROJECT_VERSION`, `YYMMDDHHMM`), so two uploads
never collide; `MARKETING_VERSION` comes from `project.yml`.

The build is verified up to the export; the first upload waits on the
sign-in described under [Before the first upload](#before-the-first-upload-one-thing-only-the-owner-can-do).

`LAA_EXPORT_DESTINATION=export` stops after writing the `.ipa` to
`build/laa/export` and uploads nothing — the way to check signing without
spending a build number.

## What the build is

| | |
|---|---|
| Team | `PAW258GB42` |
| App | `com.laa-inc.laa` — display name `LAA`, App Store Connect app `6828276003` (SKU `laa-ios`) |
| Widgets | `com.laa-inc.laa.widgets` |
| Notification Service | `com.laa-inc.laa.NotificationService` |
| Share Extension | `com.laa-inc.laa.ShareExtension` |
| Watch app | `com.laa-inc.laa.watchkitapp`, widgets `com.laa-inc.laa.watchkitapp.widgets` |
| Notification App Group | `group.com.laa-inc.laa.notifications` |
| Launcher App Group | `group.com.laa-inc.laa.launcher` |
| Signing | automatic, App Store Connect API key, `-allowProvisioningUpdates` |
| Icon | `AppIcon-LAA` (Icon Composer `.icon` for iOS 26+, the appiconset in Assets.xcassets below it) |
| Relay | `https://mac-mini.tailc9b8e7.ts.net:9443` (scripts/laa/relay-install.sh) |

Entitlements live in `scripts/laa/entitlements/`, not beside the App Store
app's, so the two builds never sign each other's capabilities.

- **Left out:** CarPlay voice-based conversation, the Location Push service
  (`com.apple.developer.location.push`) and the `ConduitLocationPush`
  extension that exists only for it. Both entitlements are granted by Apple on
  request, which this account doesn't have; a build carrying one fails to
  sign. `project-laa.yml` drops the extension from the app's dependencies.
- **Kept:** HealthKit, push, both App Groups, the Share Extension and the
  Watch app — self-service capabilities automatic signing adds on first
  archive.

App Group IDs reach the code through `CONDUIT_NOTIFICATION_APP_GROUP` and
`CONDUIT_LAUNCHER_APP_GROUP`, which each target's Info.plist passes to
`NotificationE2E.appGroup` and `WidgetSnapshotStore.appGroup`; upstream's
groups are the defaults in `project.yml`. Nothing outside `project-laa.yml`
and `scripts/laa/entitlements/` names an LAA-specific value, so an upstream
merge stays small.

`ITSAppUsesNonExemptEncryption` is `false` in `Conduit/Info.plist` (TLS and
nothing else), which is what App Store Connect's export compliance asks.

`EXCLUDED_SOURCE_FILE_NAMES: Info.plist` in `project-laa.yml` is load-bearing
on Xcode 27: the spec hands every target its whole folder, and Xcode 27's build
system refuses a target whose Info.plist is both processed and copied
("Multiple commands produce …/Info.plist"). Xcode 26 lets it through.

`CODE_SIGN_IDENTITY: "Apple Development"` in the same targets is load-bearing
too, in both directions: `Apple Distribution` is the "conflicting code signing
identity" error, and leaving it empty archives unsigned — and an unsigned
archive loses the entitlements before `-exportArchive` signs with the store
profile.

## Before the first upload: one thing only the owner can do

`xcodebuild` with the App Store Connect API key stops at

```
error: Authentication failed: Make sure a bearer token was provided, it is
properly configured and signed, and it has not expired.
```

for every target, then falls back to the team's wildcard profile and fails on
"doesn't support the group.com.laa-inc.laa.* App Group". The cause is not the
key. Measured on 2026-10-29: the same key fetched the team's capabilities and
minted store profiles for all five bundles (in
`~/Library/Developer/Xcode/UserData/Provisioning Profiles`, with
`aps-environment` = production and `application-groups` **empty**), and a build
whose entitlements ask only for what the App IDs already carry provisions fine.
What Xcode cannot do with a key is change an App ID: adding the App Groups and
HealthKit is an Apple-ID operation, and the App Store Connect API doesn't expose
App Group assignment at all (`PATCH bundleIdCapabilities` takes only
`ICLOUD_VERSION`, `DATA_PROTECTION_PERMISSION_LEVEL` and
`APPLE_ID_AUTH_APP_CONSENT`).

So the one step left needs the owner: **Xcode > Settings > Accounts > + >
Apple ID (team PAW258GB42)**. `scripts/laa/testflight.sh` notices the account
(`IDEProvisioningTeams`) and drops the API key for signing, so the first
archive then registers the App Groups and HealthKit on the four App IDs and
makes the profiles. Without it, the alternative is the same thing by hand:
developer.apple.com > Certificates, Identifiers & Profiles > Identifiers >
App Groups > `group.com.laa-inc.laa.notifications` and
`group.com.laa-inc.laa.launcher` > Configure > tick all four App IDs, and
HealthKit on `com.laa-inc.laa`.

After the first upload, confirm the entitlements travelled:

```sh
codesign -d --entitlements :- build/laa/export/Conduit.ipa
```

must list `aps-environment` = `production` and both `group.com.laa-inc.laa.*`
groups in the app and each extension. A build without them has no shared
container, so encrypted notifications and the widgets' chat index stop working;
that is why nothing is uploaded until they are in.

## The personal install path

`scripts/laa/install-on-iphone.sh` (`project-personal.yml`) still builds the
app for a cable install with a free Apple ID: no push, App Groups, HealthKit,
widgets or Watch. Use it only for a device that TestFlight can't reach, or to
test a change without an upload; it is not how the LAA app is shipped.

## Push: alerts and VoIP rings

One relay serves one app bundle — its `APNS_TOPIC` is `com.laa-inc.laa` — so
the LAA app can't use upstream's shared `push.milim.dev`, which pushes to
`com.milim.relay`. This Mac runs a relay of its own:

```sh
scripts/laa/relay-install.sh            # install, start, publish on the tailnet
scripts/laa/relay-install.sh status     # launch agent, health, tailnet address
scripts/laa/relay-install.sh uninstall  # the rollback
```

- The source is the relay shipped with the installed `conduit_push` plugin
  (`~/.hermes/plugins/conduit_push/relay`, `hermes plugins update
  conduit_push`), copied into `~/.local/share/laa-conduit-relay-laa/app`, so a
  plugin update never changes a running relay by itself.
- launchd job `com.laa.conduit-relay-laa` runs `scripts/laa/relay-run.sh`,
  which asks 1Password for the APNs key (`~/.config/laa/conduit-relay-laa.env.tpl`,
  item "APNs Auth Key (LAA)", key `8P6ANW8JG8`), writes it to a 0600 file under
  `~/.config/laa/tmp-secrets` for the relay's lifetime only, and removes it
  when the relay exits.
- It listens on `127.0.0.1:9120`, and `tailscale serve --https=9443` publishes
  it on the tailnet as `https://mac-mini.tailc9b8e7.ts.net:9443` — the
  `CONDUIT_DEFAULT_RELAY_URL` in `project-laa.yml`. Phone and Mac must both be
  on the tailnet, as Hermes already requires.
- Check it end to end without a phone: `curl -fsS
  http://127.0.0.1:9120/healthz` → `{"ok":true}`.

**Move notifications to LAA.** A profile pairs with exactly one relay. In the
LAA app, turn on notifications, connect the dashboard, and use Settings >
Notifications > 「全社員の通知をこのiPhoneへ」. The app reads that dashboard's
profile list and pairs one profile at a time, leaving profiles already paired
to this iPhone alone. It shows each result and offers a retry for failures.
This moves the selected profiles' notifications and calls from their previous
phone or relay. To pair a profile manually instead, claim a code in the LAA app
and run on the Mac:

```sh
hermes -p <profile> conduit-push pair --relay-url https://mac-mini.tailc9b8e7.ts.net:9443 <code>
hermes -p <profile> conduit-push test
```

To return a profile's notifications, keep or reinstall the App Store Conduit
app, open Settings > Notifications there, and pair that profile with the phone.
The plugin replaces the LAA pairing; the old pairing is not restored
automatically.

## When the toolchain fights back

- **A GitHub password dialog during the build.** Nothing in this build needs a
  credential: the WebRTC package is public. `scripts/laa/testflight.sh` exports
  `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=/usr/bin/false` and
  `GIT_CONFIG_GLOBAL=/dev/null` for the whole run, and resolves the package
  through the system git (`-scmProvider system`) before archiving, so a
  credential request fails in `build/laa/resolve.log` instead of reaching the
  login keychain.
- **SwiftPM stalls on the WebRTC artifact** (`Checking out 153.0.0 of package
  'WebRTC'` and no bytes arrive, 2026-10-29 on this Mac). Download release
  153.0.0 by hand, check its sha256 is
  `3e3a8946f27510133e3feed04d05fa23505bbe366e977620503bfc7986c2b78f`, unzip it,
  and pass the extracted bundle:

  ```sh
  LAA_WEBRTC_XCFRAMEWORK=/path/to/WebRTC.xcframework scripts/laa/testflight.sh
  ```

  The project then builds against that copy through a generated local package
  under `build/laa/WebRTC-local`; CI keeps resolving the package the usual way.
- **`cannot execute tool 'metal' due to missing Metal Toolchain`.** Xcode 27
  moved the shader compiler into a downloadable component:
  `xcodebuild -downloadComponent MetalToolchain` (838 MB; the first attempt can
  fail to fetch the catalog and succeed on a retry).
- **`Multiple commands produce …/Info.plist`.** See
  `EXCLUDED_SOURCE_FILE_NAMES` above; it belongs in the spec, not the command.
