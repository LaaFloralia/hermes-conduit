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
provisioning sign-in described under [Before the first upload](#before-the-first-upload-the-provisioning-step).

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

## Before the first upload: the provisioning step

`xcodebuild` could not finish automatic signing with the App Store Connect API
key on 2026-10-29. Every target stopped at

```
error: Authentication failed: Make sure a bearer token was provided, it is
properly configured and signed, and it has not expired.
```

and then fell back to the team's wildcard profile, which has no Push, App
Groups or HealthKit, so the build failed those capabilities. The key itself is
fine: `scripts/laa/asc.mjs` signs a JWT with it and the API answers 200, and so
does a JWT signed from a copy of the file the script writes for xcodebuild. The
toolchain reported it twice more through a plain `xcodebuild build`
(`Authentication failed` for every target), so it is the provisioning session,
not the key.

What that leaves: the archive compiles (Xcode 27.1, WebRTC 153.0.0, Metal
toolchain installed), `-exportArchive` signs a store IPA for
`com.laa-inc.laa` / `PAW258GB42`, and its entitlements carry no
`aps-environment` and no `com.apple.security.application-groups`, because the
archive was unsigned. Uploading that would ship an app without working push or
App Groups, so no upload has been made.

To finish, give xcodebuild a provisioning session it accepts — an Apple ID in
Xcode is the one path that also assigns the App Groups to the four App IDs:

1. Xcode > Settings > Accounts > `+` > Apple ID, then pick the PAW258GB42 team
   (an app-specific password may be needed; it is the owner's own sign-in, so
   nobody else can do this step).
2. `scripts/laa/testflight.sh`. The first archive then registers the App IDs'
   capabilities and the App Groups, and creates the profiles.
Without a sign-in, the App Groups can be assigned by hand, which is what
automatic signing would have done: developer.apple.com > Certificates,
Identifiers & Profiles > Identifiers > App Groups, select
`group.com.laa-inc.laa.notifications` and `group.com.laa-inc.laa.launcher`,
Configure, and tick all four App IDs (`com.laa-inc.laa`, `.widgets`,
`.NotificationService`, `.ShareExtension`). The portal also needs HealthKit
enabled on `com.laa-inc.laa` (Capabilities) if the build is to keep it.

3. Check the upload landed with entitlements:
   `codesign -d --entitlements :- build/laa/export/Conduit.ipa` (or on the
   exported `Payload/Conduit.app`) should list `aps-environment` = `production`
   and both `group.com.laa-inc.laa.*` groups. If it does not, the App Groups
   still aren't assigned on the App IDs in the developer portal
   (Certificates, Identifiers & Profiles > Identifiers > App Groups > Configure).

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

**The one step left to a Hermes profile.** A profile pairs with exactly one
relay (its state holds one `relay_url`), so a profile that should notify the
LAA app must pair with this relay. That moves that profile's pushes off
`push.milim.dev`, where the App Store app's installation lives — an owner
decision, so it is not applied here. When it's wanted, on the phone's Settings
row for the relay: claim a pairing code in the LAA app, then

```sh
hermes -p <profile> conduit-push pair --relay-url https://mac-mini.tailc9b8e7.ts.net:9443 <code>
hermes -p <profile> conduit-push test
```

and to undo it, `hermes -p <profile> conduit-push unpair` (the profile falls
back to its previous pairing; re-pair on `https://push.milim.dev` if it had
one). Nothing about the relay itself changes, and the eight existing pairings
are untouched until someone runs the pair command.

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
