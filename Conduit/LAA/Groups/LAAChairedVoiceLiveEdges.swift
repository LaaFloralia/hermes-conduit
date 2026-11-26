#if LAA_BUILD
import Foundation

/// Live side-effect edges for `LAAChairedVoiceEffectExecutor`, reusing the
/// existing coordinator lease and the Read Aloud speech path. Not compiled
/// in the SwiftPM harness (needs app-target AVFoundation types); only this
/// file talks to real audio.
@MainActor
final class LAAChairedVoiceCoordinatorLeasing: LAAChairedVoiceAudioLeasing {
    private let canUseAudio: @MainActor () -> Bool

    init(canUseAudio: @escaping @MainActor () -> Bool) {
        self.canUseAudio = canUseAudio
    }

    func acquirePlayback(onTakenOver: @escaping @MainActor () -> Void) throws -> UUID {
        guard canUseAudio() else { throw CancellationError() }
        // Authorization only. The player is the sole AVAudioSession lease
        // owner, and only after it has actual speech data to render.
        return UUID()
    }

    func releasePlayback(_ token: UUID) {}
}

/// One line through the gateway speech stream into a playback service,
/// as `MessageReadAloudController.runPlayback` does (no Now Playing, no
/// background task, no UI state). `gateway(speakerID)` returns the
/// speaker's profile gateway, or nil (the line fails, lease released).
@MainActor
final class LAAChairedVoiceReadAloudSpeaker: LAAChairedVoiceSpeaking {
    private let playback: SpeechPlaybackService
    private let gateway: @MainActor (String) -> VoiceGatewayService?
    private let endpointGeneration: @MainActor () -> String?
    private let onLevel: @MainActor (Double) -> Void
    private var stream: VoiceSpeechStream?
    /// Bumped by every `speak` and `stop`, as Read Aloud's generation: a
    /// callback, open or finish from an older line cannot re-acquire the
    /// playback lease or touch a newer line.
    private var epoch: UInt64 = 0
    private func isCurrent(_ e: UInt64) -> Bool { epoch == e }

    init(playback: SpeechPlaybackService? = nil,
         gateway: @escaping @MainActor (String) -> VoiceGatewayService?,
         endpointGeneration: @escaping @MainActor () -> String?,
         onLevel: @escaping @MainActor (Double) -> Void) {
        self.playback = playback ?? AVSpeechPlaybackService()
        self.gateway = gateway
        self.endpointGeneration = endpointGeneration
        self.onLevel = onLevel
    }

    struct NoGateway: Error {}

    func speak(text: String, speakerID: String) async throws {
        guard let grant = endpointGeneration(), let gateway = gateway(speakerID) else { throw NoGateway() }
        epoch &+= 1
        let current = epoch
        func authorized() -> Bool {
            isCurrent(current) && endpointGeneration() == grant && !Task.isCancelled
        }
        let spoken = LAAMeetingTurn.spokenExcerpt(SpokenTextFilter.filter(text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        defer { if isCurrent(current) { stop() } }
        playback.ownershipIntent = .meetingPlayback
        playback.playbackRate = ReadAloudSpeed.closest(to: ReadAloudSpeed.current().rate).rate
        try await withTaskCancellationHandler {
            let playback = self.playback
            let opened = try await gateway.openSpeechStream(
                onStart: { rate in
                    guard authorized() else { throw CancellationError() }
                    try playback.start(sampleRate: rate)
                },
                onPCM16: { [weak self] data, rate in
                    guard let self, authorized() else { throw CancellationError() }
                    self.onLevel(Self.level(data))
                    _ = try playback.enqueuePCM16(data, sampleRate: rate)
                },
                onEncodedAudio: { [weak self] data in
                    guard let self, authorized() else { throw CancellationError() }
                    try playback.playEncodedAudioData(data)
                    self.onLevel(0.22)
                }
            )
            // The open can outlive a stop(): drop it instead of adopting it.
            guard authorized() else {
                opened.cancel()
                throw CancellationError()
            }
            stream = opened
            try await opened.append(spoken)
            _ = try await opened.finish()
            guard authorized() else { throw CancellationError() }
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
        onLevel(0)
    }

    private static func level(_ pcm: Data) -> Double {
        guard pcm.count >= 2 else { return 0 }
        return pcm.withUnsafeBytes { raw in
            var peak = 0
            for i in stride(from: 0, to: raw.count - 1, by: 16) {
                let sample = Int16(bitPattern: UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8))
                peak = max(peak, abs(Int(sample)))
            }
            return min(1, Double(peak) / 16_384)
        }
    }
}
#endif
