#if LAA_BUILD
import Foundation

/// Side-effect edge: authorization before scheduling speech. The live
/// player owns the single audio-session lease when rendering starts.
@MainActor
protocol LAAChairedVoiceAudioLeasing: AnyObject {
    /// Returns an opaque token; throws when the session cannot be taken.
    func acquirePlayback(onTakenOver: @escaping @MainActor () -> Void) throws -> UUID
    func releasePlayback(_ token: UUID)
}

/// Side-effect edge: speech for one line. Live conformance reuses the Read
/// Aloud path (`VoiceGatewayService.openSpeechStream` + `SpeechPlaybackService`).
/// `speak` returns when the line has finished playing, throws on failure
/// and must end promptly after `stop()` (cancellation).
@MainActor
protocol LAAChairedVoiceSpeaking: AnyObject {
    func speak(text: String, speakerID: String) async throws
    func stop()
}

/// Where the executor reports back. `LAAChairedVoiceBinding` conforms.
@MainActor
protocol LAAChairedVoiceEffectSink: AnyObject {
    func completed(ticket: UInt64, generation: Int)
    func stop(generation: Int)
    func audioOwnerChanged(_ owner: LAAChairedVoiceAudioOwner, generation: Int)
}

extension LAAChairedVoiceBinding: LAAChairedVoiceEffectSink {}

/// Performs the core's effects: one lease held only while lines play, one
/// line at a time, every async result checked against (ticket, generation)
/// so a stale completion can never touch audio again.
///
/// Rules
/// - Audio is acquired only on a `.speak`, which the core emits only after
///   an explicit `engage`. Nothing here starts audio on its own.
/// - Never preempts: if `audioOwner()` is not `.none` at a `.speak`, no
///   lease is taken and the binding is told to yield.
/// - Lease released on `.releaseAudio`, `.stopSpeaking`-then-drain, speech
///   error, line deadline, takeover, and `roomChanged(generation:)`.
/// - Line deadlines (Wave 3: 30 s soft / 75 s hard, from the line start):
///   soft asks the speaker to stop (`stop()`) and keeps the lease until
///   `speak` returns; that return is then treated as a failed line (lease
///   released, core told `completed`, next line re-acquires). Hard does not
///   wait for the speaker: it stops it again, drops the line, releases the
///   lease once and disengages meeting Voice (`stop`), so a noncooperative
///   synthesizer cannot hold audio or stack lines; a new explicit `engage`
///   is needed. A `speak` that returns after the hard deadline is stale.
/// - Callbacks into the binding are hopped through `schedule`, never made
///   re-entrantly from inside `perform`.
@MainActor
final class LAAChairedVoiceEffectExecutor: LAAChairedVoiceEffectHandling {
    private struct Playing {
        let ticket: UInt64
        let generation: Int
        var task: Task<Void, Never>?
        var softExpired = false
        var cancelDeadlines: [() -> Void] = []
    }

    /// Runs `work` once after `delay` on the main actor unless the returned
    /// cancel is called first. Tests inject a manual clock.
    typealias DeadlineTimer = @MainActor (Duration, @escaping @MainActor () -> Void) -> () -> Void

    nonisolated static let softLineDeadline: Duration = .seconds(30)
    nonisolated static let hardLineDeadline: Duration = .seconds(75)

    weak var sink: LAAChairedVoiceEffectSink?
    private let leasing: LAAChairedVoiceAudioLeasing
    private let speaker: LAAChairedVoiceSpeaking
    private let audioOwner: @MainActor () -> LAAChairedVoiceAudioOwner
    private let schedule: @MainActor (@escaping @MainActor () -> Void) -> Void
    private let softDeadline: Duration
    private let hardDeadline: Duration
    private let timer: DeadlineTimer

    private(set) var lease: UUID?
    private var playing: Playing?
    /// Highest generation seen; anything older is stale.
    private(set) var generation = Int.min

    var isSpeaking: Bool { playing != nil }

    init(
        leasing: LAAChairedVoiceAudioLeasing,
        speaker: LAAChairedVoiceSpeaking,
        audioOwner: @escaping @MainActor () -> LAAChairedVoiceAudioOwner,
        softDeadline: Duration = LAAChairedVoiceEffectExecutor.softLineDeadline,
        hardDeadline: Duration = LAAChairedVoiceEffectExecutor.hardLineDeadline,
        timer: DeadlineTimer? = nil,
        schedule: (@MainActor (@escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        precondition(softDeadline > .zero && hardDeadline > softDeadline, "need 0 < soft < hard")
        self.leasing = leasing
        self.speaker = speaker
        self.audioOwner = audioOwner
        self.softDeadline = softDeadline
        self.hardDeadline = hardDeadline
        self.timer = timer ?? { delay, work in
            let task = Task { @MainActor in
                try? await Task.sleep(for: delay)
                if !Task.isCancelled { work() }
            }
            return { task.cancel() }
        }
        self.schedule = schedule ?? { work in Task { @MainActor in work() } }
    }

    // MARK: LAAChairedVoiceEffectHandling

    func perform(_ effect: LAAChairedVoiceEffect, generation: Int) {
        if generation > self.generation {
            // A newer room took ownership: nothing of the old one survives.
            if self.generation != .min { tearDown() }
            self.generation = generation
        }
        switch effect {
        case .speak(let line, let ticket):
            guard generation == self.generation else { return }
            start(line, ticket: ticket, generation: generation)
        case .stopSpeaking(let ticket):
            // Tickets are unique per core, so match the ticket alone: a newer
            // bind's flush carries the new generation for the old ticket.
            guard playing?.ticket == ticket else { return }
            stopPlayback()
        case .releaseAudio:
            guard generation == self.generation else { return }
            stopPlayback()
            releaseLease()
        }
    }

    /// AppState: the room surface closed or another room opened. Safe to
    /// call repeatedly; the binding's own flush normally precedes it.
    func roomChanged(generation: Int) {
        guard generation >= self.generation else { return }
        tearDown()
        if generation > self.generation { self.generation = generation }
    }

    // MARK: Private

    private func start(_ line: LAAChairedVoiceUtterance, ticket: UInt64, generation: Int) {
        if playing != nil { stopPlayback() } // core is serial; defensive
        guard audioOwner() == .none else {
            releaseLease()
            report { $0.audioOwnerChanged(.staffCall, generation: generation) }
            return
        }
        if lease == nil {
            do {
                lease = try leasing.acquirePlayback(onTakenOver: { [weak self] in
                    self?.takenOver(generation: generation)
                })
            } catch {
                // Could not take the session: stop meeting Voice (no retry
                // loop); a new explicit engage is needed.
                report { $0.stop(generation: generation) }
                return
            }
        }
        var entry = Playing(ticket: ticket, generation: generation, task: nil)
        let speaker = self.speaker
        // No task group: the result is delivered whenever speak returns, and
        // the deadlines below never wait for it.
        entry.task = Task { @MainActor [weak self] in
            let outcome: Outcome
            do {
                try await speaker.speak(text: line.text, speakerID: line.speakerID)
                outcome = .finished
            } catch {
                outcome = Task.isCancelled ? .cancelled : .failed
            }
            self?.finished(ticket: ticket, generation: generation, outcome: outcome)
        }
        entry.cancelDeadlines = [
            timer(softDeadline) { [weak self] in self?.softExpired(ticket: ticket, generation: generation) },
            timer(hardDeadline) { [weak self] in self?.hardExpired(ticket: ticket, generation: generation) },
        ]
        playing = entry
    }

    private func isCurrent(ticket: UInt64, generation: Int) -> Bool {
        guard let current = playing else { return false }
        return current.ticket == ticket && current.generation == generation && generation == self.generation
    }

    /// Soft: cooperative stop request; the lease stays until speak returns
    /// or the hard deadline fires.
    private func softExpired(ticket: UInt64, generation: Int) {
        guard isCurrent(ticket: ticket, generation: generation), playing?.softExpired == false else { return }
        playing?.softExpired = true
        speaker.stop()
    }

    /// Hard: bounded teardown that does not depend on the speaker.
    private func hardExpired(ticket: UInt64, generation: Int) {
        guard isCurrent(ticket: ticket, generation: generation) else { return }
        stopPlayback() // clears `playing` first: any later speak result is stale
        releaseLease()
        report { $0.stop(generation: generation) }
    }

    private enum Outcome { case finished, failed, cancelled }

    private func finished(ticket: UInt64, generation: Int, outcome: Outcome) {
        // Stale: stopped, replaced, or another room. Never re-activates audio.
        guard isCurrent(ticket: ticket, generation: generation), let current = playing else { return }
        playing = nil
        current.cancelDeadlines.forEach { $0() }
        switch outcome {
        case .finished where !current.softExpired:
            break
        case .finished, .failed, .cancelled:
            // Error, or ended only after the soft stop request.
            speaker.stop()
            releaseLease()
        }
        // The core decides: next line (lease kept/re-acquired) or releaseAudio.
        report { $0.completed(ticket: ticket, generation: generation) }
    }

    private func takenOver(generation: Int) {
        guard generation == self.generation else { return }
        stopPlayback()
        releaseLease()
        report { $0.stop(generation: generation) }
    }

    private func stopPlayback() {
        guard let current = playing else { return }
        playing = nil
        current.cancelDeadlines.forEach { $0() }
        current.task?.cancel()
        speaker.stop()
    }

    private func releaseLease() {
        guard let token = lease else { return }
        lease = nil
        leasing.releasePlayback(token)
    }

    private func tearDown() {
        stopPlayback()
        releaseLease()
    }

    private func report(_ call: @escaping @MainActor (LAAChairedVoiceEffectSink) -> Void) {
        schedule { [weak self] in
            guard let sink = self?.sink else { return }
            call(sink)
        }
    }
}
#endif
