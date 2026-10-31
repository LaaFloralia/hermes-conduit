#if LAA_BUILD
import AVFoundation
import SwiftUI
import UIKit

/// BUS-332: the muted idle video must not take the audio session away from
/// the music another app is playing.
///
/// An `AVPlayer` connected to system audio activates the shared session as
/// soon as it plays (AVFoundation's `AVPlayerAudioSessionParticipation`), and
/// the app's category is the non-mixable default. So the player either leaves
/// the session alone — iOS 27 and later can disconnect it before playback —
/// or the avatar keeps its still while another app is playing.
struct StaffAvatarIdleAudioPolicy: Equatable {
    /// The avatar's existing visible / active / Reduce Motion / scrolling
    /// decision (`StaffAvatarPlaybackPolicy.shouldPlay`).
    var shouldPlay: Bool
    /// The player can be disconnected from system audio (iOS 27+, not on Mac
    /// Catalyst, where the API is unavailable).
    var canDisconnectFromSystemAudio: Bool
    /// Another app is playing right now. Read when the avatar appears, not
    /// observed: an idle avatar that starts later is judged then.
    var otherAudioPlaying: Bool

    /// Disconnecting is the only way to keep the video without touching the
    /// session; without it, another app's playback wins and the still stays.
    var startsVideo: Bool {
        shouldPlay && (canDisconnectFromSystemAudio || !otherAudioPlaying)
    }

    var disconnectsFromSystemAudio: Bool { canDisconnectFromSystemAudio }

    /// The device's own state. `shouldPlay` stays the caller's decision so a
    /// test can check both branches without a session or a device.
    @MainActor
    static func current(shouldPlay: Bool) -> Self {
#if targetEnvironment(macCatalyst)
        // The disconnect API is unavailable on Mac Catalyst: keep the
        // pre-BUS-332 behaviour there until the Catalyst branch is integrated.
        return Self(shouldPlay: shouldPlay,
                    canDisconnectFromSystemAudio: false,
                    otherAudioPlaying: false)
#else
        let canDisconnect: Bool
        if #available(iOS 27.0, *) {
            canDisconnect = true
        } else {
            canDisconnect = false
        }
        return Self(shouldPlay: shouldPlay,
                    canDisconnectFromSystemAudio: canDisconnect,
                    otherAudioPlaying: AVAudioSession.sharedInstance().isOtherAudioPlaying)
#endif
    }
}

/// Each visible avatar owns its own muted looper; the idle audio policy above
/// keeps it from taking another app's audio. The still underneath is also the
/// Reduce Motion fallback.
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
        let audio = StaffAvatarIdleAudioPolicy.current(shouldPlay: policy.shouldPlay)
        guard audio.startsVideo, let url = assets.loop else { loop.stop(); return }
        loop.play(url, disconnectingFromSystemAudio: audio.disconnectsFromSystemAudio)
    }
}

@MainActor
final class StaffAvatarLoop: ObservableObject {
    @Published private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?
    /// The player has left system audio (or never had to): only then may the
    /// video play. A start that arrives before this must not call play().
    private var readyToPlay = false
    /// Bumped by every start and stop: a disconnect that completes after the
    /// avatar moved on must not start playback.
    private var generation = 0

    private let makePlayer: () -> AVQueuePlayer
    private let makeLooper: (AVQueuePlayer, URL) -> AVPlayerLooper?
    private let disconnect: @MainActor (AVQueuePlayer) async -> Void

    /// The seams are injectable so a test can hold the disconnect open and
    /// check that nothing plays before it completes.
    init(
        makePlayer: @escaping () -> AVQueuePlayer = { AVQueuePlayer() },
        makeLooper: @escaping (AVQueuePlayer, URL) -> AVPlayerLooper? = { player, url in
            AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        },
        disconnect: @escaping @MainActor (AVQueuePlayer) async -> Void = StaffAvatarLoop.disconnectFromSystemAudio
    ) {
        self.makePlayer = makePlayer
        self.makeLooper = makeLooper
        self.disconnect = disconnect
    }

    /// Starts or resumes the muted loop. A connected player activates the
    /// audio session as soon as it plays, so on iOS 27 and later it is
    /// disconnected from system audio first, and playback waits for that.
    func play(_ url: URL, disconnectingFromSystemAudio: Bool) {
        if currentURL == url, let player {
            // The avatar may start again before the disconnect completes
            // (onAppear, scenePhase, scrolling): that start must not play the
            // still-connected player. The completion below starts playback.
            if readyToPlay { player.play() }
            return
        }
        stop()
        generation &+= 1
        let generation = generation
        let player = makePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = makeLooper(player, url)
        currentURL = url
        self.player = player
        guard disconnectingFromSystemAudio else {
            readyToPlay = true
            player.play()
            return
        }
        Task { @MainActor [weak self] in
            await self?.disconnect(player)
            // Only this start may continue it: a stop or another avatar in the
            // meantime bumped the generation.
            guard let self, self.generation == generation else { return }
            self.readyToPlay = true
            self.player?.play()
        }
    }

    func stop() {
        generation &+= 1
        readyToPlay = false
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        looper = nil
        player = nil
        currentURL = nil
    }

    /// iOS 27 and later can leave the audio session alone; elsewhere this
    /// completes at once (the idle policy only asks for the disconnect there).
    @MainActor
    static func disconnectFromSystemAudio(_ player: AVQueuePlayer) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
#if !targetEnvironment(macCatalyst)
            if #available(iOS 27.0, *) {
                // Called on an arbitrary queue; resuming the continuation from
                // there is allowed.
                player.setDisconnectedFromSystemAudio(true) { continuation.resume() }
                return
            }
#endif
            continuation.resume()
        }
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
