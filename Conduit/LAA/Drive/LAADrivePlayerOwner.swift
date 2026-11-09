#if LAA_BUILD
import AVKit
import Combine
import SwiftUI

/// Owns the authenticated source while the screen or Picture in Picture uses it.
@MainActor
final class LAADrivePlayerOwner: NSObject, ObservableObject, @preconcurrency AVPlayerViewControllerDelegate {
    @Published private(set) var state: LAADrivePlaybackState = .loading
    let source: LAADrivePlayer
    let playback: LAADrivePlaybackCoordinator
    private let audio: LAADriveAudioLease
    private let autoPlay: Bool
    private var subscriptions: Set<AnyCancellable> = []
    private var visible = false
    private var pictureInPicture = false
    private var invalidated = false
    var canRetry: Bool { !invalidated }
    private var accessTask: Task<Void, Never>?
    private static var pictureInPictureOwners: [ObjectIdentifier: LAADrivePlayerOwner] = [:]

    init(item: LAADriveItem, bridge: LAABridgeSession, studioPath: String?, autoPlay: Bool, localURL: URL? = nil) {
        let source = LAADrivePlayer(item: item, bridge: bridge, studioPath: studioPath, localURL: localURL)
        let audio = LAADriveAudioLease()
        let contentID = studioPath ?? item.id
        let version = studioPath == nil ? item.version : "content-addressed"
        let identity = LAADrivePlaybackIdentity(pairingID: bridge.deviceID, contentID: contentID, version: version)
        let playback = LAADrivePlaybackCoordinator(
            player: source.player, identity: identity,
            openSource: { source.open() }, closeSource: { source.close() },
            acquireAudio: { try audio.acquire() }, releaseAudio: { audio.release() })
        self.source = source; self.audio = audio; self.playback = playback; self.autoPlay = autoPlay
        super.init()
        audio.onTakeover = { [weak playback] in playback?.pause() }
        playback.$state.sink { [weak self] state in self?.state = state }.store(in: &subscriptions)
        source.$error.compactMap { $0 }.sink { [weak playback] message in
            playback?.reportFailure(message)
        }.store(in: &subscriptions)
        if localURL != nil {
            let revision = bridge.revision
            bridge.$revision.dropFirst().sink { [weak self] current in
                if current != revision { self?.invalidate("Macとの接続が変わりました。このファイルを開き直してください。") }
            }.store(in: &subscriptions)
        }
        VoiceAudioSessionCoordinator.shared.$isInNativeCall.removeDuplicates().sink { [weak playback] active in
            if active { playback?.pause() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak playback] notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in playback?.pause() }
            }.store(in: &subscriptions)
    }

    func appear() {
        guard !invalidated else { return }
        visible = true
        playback.start(autoPlay: autoPlay)
    }

    func disappear() {
        visible = false
        if !pictureInPicture { stop() }
    }

    /// A saved file can continue in PiP after its screen disappears. The
    /// access check must therefore live with the owner, not with the view.
    func monitorAccess(_ check: @escaping @MainActor () async throws -> Void) {
        accessTask?.cancel()
        accessTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                    try await check()
                } catch is CancellationError { return }
                catch {
                    if let failure = error as? LAADriveOfflineError,
                       failure == .forbidden || failure == .notFound || failure == .accessChanged || failure == .permissionUnknown {
                        self?.invalidate("Access to this saved file is no longer available.")
                        return
                    }
                }
            }
        }
    }

    func invalidate(_ message: String) {
        invalidated = true
        playback.reportFailure(message)
        stop()
    }

    private func stop() {
        accessTask?.cancel()
        accessTask = nil
        playback.stop()
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        pictureInPicture = true
        Self.pictureInPictureOwners[ObjectIdentifier(self)] = self
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              failedToStartPictureInPictureWithError error: Error) {
        finishPictureInPicture()
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        finishPictureInPicture()
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(visible)
    }

    private func finishPictureInPicture() {
        pictureInPicture = false
        if !visible { stop() }
        Self.pictureInPictureOwners.removeValue(forKey: ObjectIdentifier(self))
    }
}

/// The existing session coordinator remains the only authority for audio.
@MainActor
private final class LAADriveAudioLease {
    var onTakeover: (() -> Void)?
    private var lease: VoiceAudioLease?

    func acquire() throws {
        guard lease == nil else { return }
        let coordinator = VoiceAudioSessionCoordinator.shared
        guard !coordinator.isInNativeCall, !coordinator.hasOwnersOtherThanWakeListening else {
            throw LAABridgeError.unavailable
        }
        lease = try coordinator.acquire(.standalonePlayback) { [weak self] in self?.onTakeover?() }
    }

    func release() {
        guard let lease else { return }
        self.lease = nil
        VoiceAudioSessionCoordinator.shared.release(lease)
    }
}
#endif
