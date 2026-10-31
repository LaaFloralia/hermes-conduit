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

`studioPath` must pass `LAAStudioMedia.bridgePathIsValid`; it is the existing content-addressed `/v1/studio/media/...` Bridge path, not a bearer-bearing URL. The callback is optional and reports the initial state as well as changes while the view exists. PiP may outlive that view; its later changes are not delivered to a disposed callback. Loading, retry and replay controls are provided by the view. Drive uses the default `autoPlay: false`; Studio v1 opts in. A new `LAADrivePlayerView` identity is required when changing the item, path or session.

Drive owns `Conduit/LAA/Drive/LAADrivePlayer.swift`, `LAADrivePlayerOwner.swift`, `LAADrivePlaybackCoordinator.swift`, `LAADrivePlaybackState.swift` and `LAADriveNativePlayerSurface.swift`. Studio owns its call sites and can use this interface without changing Drive-owned files. The native player, Picture in Picture, AirPlay, fullscreen, restoration and audio interruptions require simulator/device validation; the authenticated resource loader has not yet been proven to work with AirPlay.
