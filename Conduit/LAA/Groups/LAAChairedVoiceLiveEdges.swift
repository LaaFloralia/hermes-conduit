#if LAA_BUILD
import Foundation

/// Live side-effect edges for `LAAChairedVoiceEffectExecutor`, reusing the
/// existing coordinator lease and the Read Aloud speech path. Not compiled
/// in the SwiftPM harness (needs app-target AVFoundation types); only this
/// file talks to real audio.
@MainActor
final class LAAChairedVoiceCoordinatorLeasing: LAAChairedVoiceAudioLeasing {
    private let coordinator: VoiceAudioSessionCoordinator
    private var leases: [UUID: VoiceAudioLease] = [:]

    init(coordinator: VoiceAudioSessionCoordinator = .shared) {
        self.coordinator = coordinator
    }

    func acquirePlayback(onTakenOver: @escaping @MainActor () -> Void) throws -> UUID {
        let lease = try coordinator.acquire(.standalonePlayback, onTakenOver: onTakenOver)
        let token = UUID()
        leases[token] = lease
        return token
    }

    func releasePlayback(_ token: UUID) {
        guard let lease = leases.removeValue(forKey: token) else { return }
        coordinator.release(lease)
    }
}

/// One line through the gateway speech stream into a playback service,
/// as `MessageReadAloudController.runPlayback` does (no Now Playing, no
/// background task, no UI state). `gateway(speakerID)` returns the
/// speaker's profile gateway, or nil (the line fails, lease released).
@MainActor
final class LAAChairedVoiceReadAloudSpeaker: LAAChairedVoiceSpeaking {
    private let playback: SpeechPlaybackService
    private let gateway: @MainActor (String) -> VoiceGatewayService?
    private var stream: VoiceSpeechStream?
    /// Bumped by every `speak` and `stop`, as Read Aloud's generation: a
    /// callback, open or finish from an older line cannot re-acquire the
    /// playback lease or touch a newer line.
    private var epoch: UInt64 = 0
    private func isCurrent(_ e: UInt64) -> Bool { epoch == e }

    init(playback: SpeechPlaybackService? = nil,
         gateway: @escaping @MainActor (String) -> VoiceGatewayService?) {
        self.playback = playback ?? AVSpeechPlaybackService()
        self.gateway = gateway
    }

    struct NoGateway: Error {}

    func speak(text: String, speakerID: String) async throws {
        guard let gateway = gateway(speakerID) else { throw NoGateway() }
        epoch &+= 1
        let current = epoch
        playback.ownershipIntent = .standalonePlayback
        playback.playbackRate = ReadAloudSpeed.closest(to: ReadAloudSpeed.current().rate).rate
        try await withTaskCancellationHandler {
            let playback = self.playback
            let opened = try await gateway.openSpeechStream(
                onStart: { [weak self] rate in
                    guard let self, self.isCurrent(current) else { return }
                    try playback.start(sampleRate: rate)
                },
                onPCM16: { [weak self] data, rate in
                    guard let self, self.isCurrent(current) else { return }
                    _ = try playback.enqueuePCM16(data, sampleRate: rate)
                },
                onEncodedAudio: { [weak self] data in
                    guard let self, self.isCurrent(current) else { return }
                    try playback.playEncodedAudioData(data)
                }
            )
            // The open can outlive a stop(): drop it instead of adopting it.
            guard isCurrent(current), !Task.isCancelled else {
                opened.cancel()
                throw CancellationError()
            }
            stream = opened
            let spoken = SpokenTextFilter.filter(text)
            try await opened.append(spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : spoken)
            _ = try await opened.finish()
            guard isCurrent(current), !Task.isCancelled else { throw CancellationError() }
            stream = nil
            try playback.finish()
            await playback.drain()
            guard isCurrent(current) else { throw CancellationError() }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in
                // A late cancel of an older line must not stop a newer one.
                guard let self, self.isCurrent(current) else { return }
                self.stop()
            }
        }
    }

    func stop() {
        epoch &+= 1
        stream?.cancel()
        stream = nil
        playback.stop()
    }
}
#endif
