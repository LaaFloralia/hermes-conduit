# Shared Drive / Studio player

Studio may display a Bridge media asset with:

```swift
LAADrivePlayerView(
    item: item,                    // LAADriveItem with id, name and MIME type
    bridge: bridge,                // the current LAABridgeSession
    studioPath: validatedPath,     // Studio Bridge media path; nil for Drive
    autoPlay: true                 // optional, defaults to false
) { state in
    // LAADrivePlaybackState: .loading, .paused, .playing,
    // .ended or .failed(String). Called on the main actor.
}
.id("\(bridge.revision):\(validatedPath)")
```

`studioPath` must pass `LAAStudioMedia.bridgePathIsValid`; it is the existing content-addressed `/v1/studio/media/...` Bridge path, not a bearer-bearing URL. The callback is optional and reports the initial state as well as changes while the view exists. PiP may outlive that view; its later changes are not delivered to a disposed callback. A loading status, retry and replay controls are provided by the view; optional `poster: UIImage?` stays visible while preparing playback. `showsDetails: Bool = false` opts into Drive’s edge-to-edge player with the file name/size below the video; embedded Studio and offline players retain their default layout. Drive previews opt into autoplay on a file tap; the reusable view still defaults to `autoPlay: false`. Studio opts in at its own call sites. A new `LAADrivePlayerView` identity is required when changing the item, path or session.

`LAABridgeSession.driveRange(path:offset:length:expectedVersion:timeout:)` is the shared bounded transport. Both `expectedVersion: String? = nil` and `timeout: TimeInterval? = nil` are optional; the request retains its 30-second default when `timeout` is omitted. Studio paths omit `expectedVersion`. The merged `LAADriveTransport.swift` and `LAABridgeStatus.swift` forward both arguments, including Studio v2's timeout. Drive's filesystem adapter supplies decimal versions and 206/416 range responses through the same transport.

Drive owns `Conduit/LAA/Drive/LAADrivePlayer.swift`, `LAADrivePlayerOwner.swift`, `LAADrivePlaybackCoordinator.swift`, `LAADrivePlaybackState.swift` and `LAADriveNativePlayerSurface.swift`. Studio owns its call sites and can use this interface without changing Drive-owned files. The native player, Picture in Picture, AirPlay, fullscreen, restoration and audio interruptions require simulator/device validation; the authenticated resource loader has not yet been proven to work with AirPlay.

The remote resource loader requests a small first part (at most 256 KiB), then bounded 512 KiB parts with a sliding window of at most eight parts (4 MiB) per AVFoundation request. It cancels obsolete windows on seek and pins every part to the resolved decimal version. A versioned listing's size/MIME can satisfy the initial content-information probe; actual media still requires fresh Bridge metadata checks. Remote items prefer three seconds of forward buffering; local files retain fifteen. The coordinator keeps automatic stalling waits enabled to retain native pause intent, but bypasses the custom-loader network prediction once an actual second of contiguous media is buffered. It does not auto-resume an explicit pause.

Google's Bridge adapter overlaps fresh metadata with **closed ranges no larger than 512 KiB**, then validates permissions/version before sending any bytes. HEAD and larger/unbounded requests retain their original path. It retries a read once after an invalidated OAuth access token; writes are never replayed. This is not a revision-pinned download: Google can still change the file between the metadata check and media response. Bridge changes require the operator to restart the running Bridge after integration.

Drive lists retain the previous page during refresh, keep a bounded in-memory page cache in front of the existing protected metadata cache, and page server-side type filters (`type=video|image|document`; omitted means all). Server-side `order=recent` sorts by modification time before pagination; default order is by name. Cursors bind to type/order as well as folder/query/view/page size. Thumbnails request 480 px where Google's URL exposes a size, use at most six concurrent transfers, decode off the main actor, and cache by device/file/thumbnail version. The protected disk cache is limited to 32 MiB/100 entries/24 hours; known access loss or pairing changes clear it. No Google credential or raw file/device identifier is stored in thumbnail filenames.
