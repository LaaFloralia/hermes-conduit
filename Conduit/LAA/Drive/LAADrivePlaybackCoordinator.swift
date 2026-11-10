#if LAA_BUILD
import Foundation
import AVFoundation
import Combine

/// Tracks the AVPlayer itself, including changes made by the native controls.
/// The owner opens/closes the authenticated source and owns PiP presentation.
@MainActor
final class LAADrivePlaybackCoordinator: ObservableObject {
    @Published private(set) var state: LAADrivePlaybackState = .loading
    let player: AVPlayer

    private let openSource: () -> Void
    private let closeSource: () -> Void
    private let acquireAudio: () throws -> Void
    private let releaseAudio: () -> Void
    private let resumeStore: LAADriveResumeStore
    private let identity: LAADrivePlaybackIdentity?
    private let playbackFailureMessage: String
    private let audioFailureMessage: String
    private let startsBufferedPlayback: Bool
    private var currentItemObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var bufferedRangesObservation: NSKeyValueObservation?
    private var waitingReasonObservation: NSKeyValueObservation?
    private var endObservation: NSObjectProtocol?
    private var timeObserver: Any?
    private weak var observedItem: AVPlayerItem?
    private var generation = 0
    private var active = false
    private var restored = false
    private var seeking = false
    private var wantsPlay = false
    private var ended = false
    private var failure: String?
    private var ownsAudio = false
    private var preferredMuted = false

    /// `openSource` must synchronously install an AVPlayerItem or report failure.
    init(player: AVPlayer, identity: LAADrivePlaybackIdentity?, resumeStore: LAADriveResumeStore? = nil,
         playbackFailureMessage: String = "このファイルを再生できませんでした。",
         audioFailureMessage: String = "いまは音声を再生できません。",
         startsBufferedPlayback: Bool = false,
         openSource: @escaping () -> Void, closeSource: @escaping () -> Void,
         acquireAudio: @escaping () throws -> Void, releaseAudio: @escaping () -> Void) {
        self.player = player
        self.identity = identity
        self.resumeStore = resumeStore ?? LAADriveResumeStore()
        self.playbackFailureMessage = playbackFailureMessage
        self.audioFailureMessage = audioFailureMessage
        self.startsBufferedPlayback = startsBufferedPlayback
        self.openSource = openSource
        self.closeSource = closeSource
        self.acquireAudio = acquireAudio
        self.releaseAudio = releaseAudio
    }

    /// Autoplay is a caller choice; calling start twice does not restart playback.
    func start(autoPlay: Bool) {
        guard !active else { return }
        generation &+= 1
        active = true; restored = false; seeking = false
        wantsPlay = autoPlay; ended = false; failure = nil
        // Native controls can call AVPlayer.play() without going through us.
        // Keep output muted until the audio-session owner has been acquired.
        preferredMuted = player.isMuted
        player.isMuted = true
        player.pause()
        transition(.loading)
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.bindCurrentItem() }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        waitingReasonObservation = player.observe(\.reasonForWaitingToPlay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.savePosition() }
        }
        openSource()
        bindCurrentItem()
        if player.currentItem == nil { reportFailure(playbackFailureMessage) }
    }

    func play() {
        guard active, failure == nil else { return }
        if ended { replay(); return }
        guard restored, !seeking else { wantsPlay = true; return }
        guard beginAudio() else { return }
        player.play()
        refresh()
    }

    func pause() {
        guard active else { return }
        wantsPlay = false
        player.pause()
        savePosition()
        endAudio()
        refresh()
    }

    /// The owner maps its authenticated loader errors to a safe user message.
    func reportFailure(_ message: String) {
        guard active, failure == nil else { return }
        savePosition()
        let displayMessage = message.isEmpty ? playbackFailureMessage : message
        failure = displayMessage
        wantsPlay = false
        player.pause()
        endAudio()
        transition(.failed(displayMessage))
    }

    /// A retry represents an explicit request to try playing again.
    func retry() {
        guard active, failure != nil else { return }
        stop()
        start(autoPlay: true)
    }

    func replay() {
        guard active, ended, failure == nil, let item = player.currentItem else { return }
        ended = false; seeking = true; wantsPlay = true
        resumeStore.clear(identity)
        player.pause()
        transition(.loading)
        let expectedGeneration = generation
        player.seek(to: .zero) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.active, self.generation == expectedGeneration,
                      self.player.currentItem === item, self.failure == nil else { return }
                self.seeking = false
                self.wantsPlay = false
                self.play()
            }
        }
    }

    /// Do not call while PiP still owns the player; the owner decides that lifecycle.
    func stop() {
        guard active else { return }
        savePosition()
        active = false; generation &+= 1; wantsPlay = false
        player.pause()
        endAudio()
        currentItemObservation = nil; timeControlObservation = nil; itemStatusObservation = nil
        bufferedRangesObservation = nil; waitingReasonObservation = nil
        if let endObservation { NotificationCenter.default.removeObserver(endObservation); self.endObservation = nil }
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        observedItem = nil
        closeSource()
        player.isMuted = preferredMuted
    }

    private func bindCurrentItem() {
        guard active else { return }
        guard let item = player.currentItem else { refresh(); return }
        if observedItem === item { refresh(); return }
        itemStatusObservation = nil
        bufferedRangesObservation = nil
        if let endObservation { NotificationCenter.default.removeObserver(endObservation) }
        observedItem = item
        restored = false; seeking = false; ended = false
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else { return }
                self.itemStatusChanged(item)
            }
        }
        bufferedRangesObservation = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        endObservation = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                 object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.active, self.player.currentItem === item else { return }
                self.ended = true; self.wantsPlay = false
                self.resumeStore.clear(self.identity)
                self.player.pause(); self.endAudio()
                self.transition(.ended)
            }
        }
        itemStatusChanged(item)
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard active, player.currentItem === item else { return }
        switch item.status {
        case .failed: reportFailure(playbackFailureMessage)
        case .readyToPlay:
            guard !restored, !seeking else { refresh(); return }
            let duration = item.duration.seconds
            guard let position = resumeStore.position(for: identity, duration: duration) else {
                restored = true
                playIfRequested()
                return
            }
            seeking = true
            let expectedGeneration = generation
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) { [weak self, weak item] _ in
                Task { @MainActor in
                    guard let self, let item, self.active, self.generation == expectedGeneration,
                          self.player.currentItem === item, self.failure == nil else { return }
                    self.seeking = false; self.restored = true
                    self.playIfRequested()
                }
            }
        case .unknown: refresh()
        @unknown default: reportFailure(playbackFailureMessage)
        }
    }

    private func playIfRequested() {
        if wantsPlay { wantsPlay = false; play() } else { refresh() }
    }

    private func refresh() {
        guard active else { return }
        if let failure { transition(.failed(failure)); return }
        guard let item = player.currentItem else { transition(.loading); return }
        if item.status == .failed { reportFailure(playbackFailureMessage); return }
        if ended {
            if player.timeControlStatus != .paused { replay() } else { transition(.ended) }
            return
        }
        guard item.status == .readyToPlay, restored, !seeking else {
            // A native control can be pressed before the saved position is
            // restored. Resume that request only after the seek completes.
            if player.timeControlStatus != .paused { wantsPlay = true; player.pause() }
            transition(.loading)
            return
        }
        switch player.timeControlStatus {
        case .playing:
            guard beginAudio() else { return }
            transition(.playing)
        case .waitingToPlayAtSpecifiedRate:
            guard beginAudio() else { return }
            transition(.loading)
            startBufferedContent(item)
        case .paused:
            if state == .playing || state == .loading { savePosition() }
            endAudio()
            transition(.paused)
        @unknown default: transition(.loading)
        }
    }

    private func startBufferedContent(_ item: AVPlayerItem) {
        guard startsBufferedPlayback,
              player.reasonForWaitingToPlay == .toMinimizeStalls || player.reasonForWaitingToPlay == .evaluatingBufferingRate else { return }
        // AVFoundation's network prediction does not understand our resource
        // loader. Start actual buffered media instead of waiting for that
        // prediction. Keep automatic waiting enabled so an empty buffer retains
        // playback intent; a native pause always cancels that waiting state.
        let position = player.currentTime().seconds
        guard position.isFinite, item.loadedTimeRanges.contains(where: { value in
            let range = value.timeRangeValue
            let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            return start.isFinite && end.isFinite && start <= position + 0.05 && end - position >= min(1, max(0.1, item.duration.seconds - position))
        }) else { return }
        player.playImmediately(atRate: player.defaultRate)
    }

    private func beginAudio() -> Bool {
        if ownsAudio { return true }
        do {
            try acquireAudio()
            ownsAudio = true
            player.isMuted = preferredMuted
            return true
        }
        catch { reportFailure(audioFailureMessage); return false }
    }

    private func endAudio() {
        guard ownsAudio else { return }
        ownsAudio = false
        preferredMuted = player.isMuted
        player.isMuted = true
        releaseAudio()
    }

    private func savePosition() {
        guard active, restored, !seeking, !ended, player.currentItem?.status == .readyToPlay else { return }
        resumeStore.save(player.currentTime().seconds, for: identity)
    }

    private func transition(_ next: LAADrivePlaybackState) {
        if state != next { state = next }
    }
}
#endif
