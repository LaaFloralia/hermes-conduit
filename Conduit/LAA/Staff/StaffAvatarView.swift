#if LAA_BUILD
import AVFoundation
import SwiftUI
import UIKit

/// Each visible avatar owns its own muted looper; it never changes the app's
/// audio session. The still underneath is also the Reduce Motion fallback.
struct StaffAvatarView: View {
    let profile: String
    let name: String
    var fallbackURL: URL? = nil
    var size: CGFloat = 40
    var scrolling = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @StateObject private var loop = StaffAvatarLoop()

    private var assets: StaffAssets { StaffAssetResolver.bundled.resolve(profile: profile) }
    private var policy: StaffAvatarPlaybackPolicy {
        StaffAvatarPlaybackPolicy(visible: visible, active: scenePhase == .active,
                                  reduceMotion: reduceMotion, lowPower: lowPower,
                                  scrolling: scrolling, hasLoop: assets.loop != nil && assets.avatar != nil)
    }

    var body: some View {
        ZStack {
            still
            if let player = loop.player, policy.shouldPlay {
                StaffVideoLayer(player: player)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .onAppear { visible = true; syncPlayback() }
        .onDisappear { visible = false; loop.stop() }
        .onChange(of: policy) { _, _ in syncPlayback() }
        .onChange(of: profile) { _, _ in loop.stop(); syncPlayback() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    @ViewBuilder private var still: some View {
        if let url = assets.avatar, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let url = assets.defaultMark, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).renderingMode(.template).resizable().scaledToFit()
                .foregroundStyle(LAAColors.teal)
                .padding(size * 0.20)
                .background(LAAColors.surface)
        } else {
            ProfileAvatarView(profile: profile, displayName: name, url: fallbackURL, size: size)
        }
    }

    private func syncPlayback() {
        guard policy.shouldPlay, let url = assets.loop else { loop.stop(); return }
        loop.play(url)
    }
}

@MainActor
private final class StaffAvatarLoop: ObservableObject {
    @Published private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    func play(_ url: URL) {
        if currentURL == url, let player { player.play(); return }
        stop()
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        currentURL = url
        self.player = player
        player.play()
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        looper = nil
        player = nil
        currentURL = nil
    }
}

private struct StaffVideoLayer: UIViewRepresentable {
    let player: AVQueuePlayer
    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layerPlayer.videoGravity = .resizeAspectFill
        view.layerPlayer.player = player
        return view
    }
    func updateUIView(_ view: PlayerView, context: Context) { view.layerPlayer.player = player }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var layerPlayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#endif
