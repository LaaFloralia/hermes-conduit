#if LAA_BUILD
import XCTest
@testable import Conduit

/// Executor + binding + core with fake lease/speech edges and a manual
/// scheduler. No audio session, TTS, mic, device or network.
@MainActor
final class LAAChairedVoiceEffectExecutorTests: XCTestCase {
    private final class FakeLeasing: LAAChairedVoiceAudioLeasing {
        var held: Set<UUID> = []
        var acquires = 0
        var releases: [UUID: Int] = [:]
        var failNext = false
        var takeover: (@MainActor () -> Void)?
        func acquirePlayback(onTakenOver: @escaping @MainActor () -> Void) throws -> UUID {
            if failNext { failNext = false; throw CancellationError() }
            acquires += 1
            let id = UUID(); held.insert(id); takeover = onTakenOver; return id
        }
        func releasePlayback(_ token: UUID) { held.remove(token); releases[token, default: 0] += 1 }
    }

    private final class FakeSpeaker: LAAChairedVoiceSpeaking {
        var spoken: [String] = []
        var stops = 0
        private var pending: [CheckedContinuation<Void, Error>] = []
        func speak(text: String, speakerID: String) async throws {
            spoken.append(text)
            try await withCheckedThrowingContinuation { pending.append($0) }
        }
        func stop() {
            stops += 1
            let all = pending; pending = []
            all.forEach { $0.resume(throwing: CancellationError()) }
        }
        var waiting: Int { pending.count }
        func finish() { guard !pending.isEmpty else { return }; pending.removeFirst().resume() }
        func fail() { guard !pending.isEmpty else { return }; pending.removeFirst().resume(throwing: URLError(.timedOut)) }
    }

    /// Deterministic clock: deadlines fire only on `advance`, no real wait.
    private final class ManualClock {
        private var now: Duration = .zero
        private var items: [(id: Int, at: Duration, work: @MainActor () -> Void)] = []
        private var nextID = 0
        private(set) var cancelled = 0
        var pending: Int { items.count }
        func timer(_ delay: Duration, _ work: @escaping @MainActor () -> Void) -> () -> Void {
            nextID += 1
            let id = nextID
            items.append((id, now + delay, work))
            return { [weak self] in
                guard let self, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items.remove(at: i); self.cancelled += 1
            }
        }
        @MainActor func advance(_ by: Duration) {
            now += by
            let due = items.filter { $0.at <= now }.sorted { $0.at < $1.at }
            items.removeAll { $0.at <= now }
            due.forEach { $0.work() }
        }
    }

    /// Ignores stop() entirely; speak returns only when the test says so.
    private final class NoncooperativeSpeaker: LAAChairedVoiceSpeaking {
        var spoken: [String] = []
        var stops = 0
        var pending: [CheckedContinuation<Void, Error>] = []
        func speak(text: String, speakerID: String) async throws {
            spoken.append(text)
            try await withCheckedThrowingContinuation { pending.append($0) }
        }
        func stop() { stops += 1 }
        func lateFinish() { let all = pending; pending = []; all.forEach { $0.resume() } }
    }

    private let room = "room-x"
    private var queued: [@MainActor () -> Void] = []
    private var owner: LAAChairedVoiceAudioOwner = .none
    // The binding holds its handler weakly (as AppState must hold the
    // executor strongly), so the test keeps it alive.
    private var retained: LAAChairedVoiceEffectExecutor?

    private func drain() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
            let work = queued; queued = []
            work.forEach { $0() }
        }
    }

    private func memberMsg(_ seq: Int, _ text: String) -> GroupEvent {
        GroupEvent(roomID: room, seq: seq, eventID: "m\(seq)", kind: "message.member",
                   actor: GroupActor(kind: "member", id: "hortensia", profile: "hortensia", displayName: nil, connectionID: nil),
                   authorityEpoch: 1, payload: ["text": .string(text), "thread_id": .string("t")], createdAt: Double(seq))
    }

    private func settled(_ seq: Int, _ message: String) -> GroupEvent {
        GroupEvent(roomID: room, seq: seq, eventID: "s\(seq)", kind: "turn.settled",
                   actor: GroupActor(kind: "gateway", id: "gw", profile: nil, displayName: nil, connectionID: nil),
                   authorityEpoch: 1, payload: ["message_event_id": .string(message)], createdAt: Double(seq))
    }

    private func lines(_ seqs: [Int], from start: Int = 100) -> [GroupEvent] {
        seqs.enumerated().flatMap { i, s in [memberMsg(s, "line\(s)"), settled(start + i, "m\(s)")] }
    }

    private let clock = ManualClock()

    private func make(generation: Int = 1)
        -> (LAAChairedVoiceBinding, LAAChairedVoiceEffectExecutor, FakeLeasing, FakeSpeaker) {
        let leasing = FakeLeasing(), speaker = FakeSpeaker()
        let executor = LAAChairedVoiceEffectExecutor(
            leasing: leasing, speaker: speaker, audioOwner: { [unowned self] in self.owner },
            timer: { [unowned self] in self.clock.timer($0, $1) },
            schedule: { [unowned self] in self.queued.append($0) })
        let binding = LAAChairedVoiceBinding(handler: executor)
        executor.sink = binding
        retained = executor
        binding.bind(roomID: room, generation: generation)
        return (binding, executor, leasing, speaker)
    }

    func testNoAudioBeforeExplicitEngage() async {
        let (binding, _, leasing, speaker) = make()
        binding.ingest(lines([1, 2]), generation: 1, owner: .none)
        await drain()
        XCTAssertEqual(leasing.acquires, 0)
        XCTAssertEqual(speaker.spoken, [])
    }

    func testSerialPlaybackHoldsOneLeaseAndReleasesOnDrain() async {
        let (binding, executor, leasing, speaker) = make()
        XCTAssertNil(binding.engage(generation: 1, backlogThroughSeq: nil, owner: .none))
        binding.ingest(lines([1, 2]), generation: 1, owner: .none)
        await drain()
        XCTAssertEqual(speaker.spoken, ["line1"])
        speaker.finish(); await drain()
        XCTAssertEqual(speaker.spoken, ["line1", "line2"])
        XCTAssertEqual(leasing.acquires, 1, "one lease across the queue")
        speaker.finish(); await drain()
        XCTAssertTrue(leasing.held.isEmpty, "released when the queue drains")
        XCTAssertNil(executor.lease)
    }

    func testStopCancelsReleasesAndStaleCompletionNeverReactivates() async {
        let (binding, executor, leasing, speaker) = make()
        binding.engage(generation: 1, backlogThroughSeq: nil, owner: .none)
        binding.ingest(lines([1, 2]), generation: 1, owner: .none)
        await drain()
        binding.stop(generation: 1)
        await drain()
        XCTAssertTrue(leasing.held.isEmpty)
        XCTAssertFalse(executor.isSpeaking)
        binding.completed(ticket: 1, generation: 1) // late completion
        binding.ingest(lines([1, 2, 3], from: 200), generation: 1, owner: .none)
        await drain()
        XCTAssertEqual(speaker.spoken, ["line1"])
        XCTAssertEqual(leasing.acquires, 1, "nothing re-acquired after Stop")
    }

    func testErrorReleasesLeaseThenNextLineReacquires() async {
        let (binding, _, leasing, speaker) = make()
        binding.engage(generation: 1, backlogThroughSeq: nil, owner: .none)
        binding.ingest(lines([1, 2]), generation: 1, owner: .none)
        await drain()
        speaker.fail(); await drain()
        XCTAssertEqual(speaker.spoken, ["line1", "line2"])
        XCTAssertEqual(leasing.acquires, 2, "lease released on error, re-acquired for the next line")
        XCTAssertEqual(leasing.held.count, 1)
        speaker.finish(); await drain()
        XCTAssertTrue(leasing.held.isEmpty)
    }

    func testDefaultDeadlinesAreThirtySoftSeventyFiveHard() {
        XCTAssertEqual(LAAChairedVoiceEffectExecutor.softLineDeadline, .seconds(30))
        XCTAssertEqual(LAAChairedVoiceEffectExecutor.hardLineDeadline, .seconds(75))
    }

    func testSoftDeadlineAsksStopKeepsLeaseUntilSpeakEnds() async {
        let (binding, _, leasing, speaker) = make()
        binding.engage(generation: 1, backlogThroughSeq: nil, owner: .none)
        binding.ingest(lines([1, 2]), generation: 1, owner: .none)
        await drain()
        clock.advance(.seconds(29)); await drain()
        XCTAssertEqual(speaker.stops, 0, "nothing before 30 s")
        // FakeSpeaker honours stop(): speak throws, line treated as failed.
        clock.advance(.seconds(1)); await drain()
        XCTAssertEqual(speaker.stops, 1)
        XCTAssertEqual(speaker.spoken, ["line1", "line2"], "core advanced to the next line")
        XCTAssertEqual(leasing.acquires, 2, "soft-ended line released its lease; next line re-acquired")
        XCTAssertEqual(leasing.held.count, 1)
        XCTAssertTrue(leasing.releases.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(clock.pending, 2, "only the new line's two deadlines remain")
        speaker.finish(); await drain()
        XCTAssertTrue(leasing.held.isEmpty)
    }

    func testHardDeadlineReleasesNoncooperativeSpeakerOnceAndIgnoresLateCompletion() async {
        let leasing = FakeLeasing(), speaker = NoncooperativeSpeaker()
        let executor = LAAChairedVoiceEffectExecutor(
            leasing: leasing, speaker: speaker, audioOwner: { .none },
            timer: { [unowned self] in self.clock.timer($0, $1) },
            schedule: { [unowned self] in self.queued.append($0) })
        let binding = LAAChairedVoiceBinding(handler: executor)
        executor.sink = binding
        retained = executor
        binding.bind(roomID: room, generation: 1)
        binding.engage(generation: 1, backlogThroughSeq: nil, owner: .none)
        binding.ingest(lines([1, 2]), generation: 1, owner: .none)
        await drain()
        clock.advance(.seconds(30)); await drain()
        XCTAssertEqual(speaker.stops, 1, "soft stop requested")
        XCTAssertEqual(leasing.held.count, 1, "soft keeps the lease while speak is still running")
        XCTAssertTrue(executor.isSpeaking)
        clock.advance(.seconds(44)); await drain()
        XCTAssertEqual(leasing.held.count, 1, "nothing at 74 s")
        clock.advance(.seconds(1)); await drain() // 75 s
        XCTAssertTrue(leasing.held.isEmpty, "hard deadline releases without speaker cooperation")
        XCTAssertNil(executor.lease)
        XCTAssertFalse(executor.isSpeaking)
        XCTAssertEqual(leasing.releases.count, 1)
        XCTAssertEqual(leasing.releases.values.first, 1, "released exactly once")
        XCTAssertEqual(binding.core.phase, .silent, "disengaged; a new explicit engage is needed")
        XCTAssertEqual(clock.pending, 0)
        // Late completion from the stuck synthesizer + further events.
        speaker.lateFinish(); await drain()
        binding.completed(ticket: 1, generation: 1)
        binding.ingest(lines([3], from: 200), generation: 1, owner: .none)
        clock.advance(.seconds(300)); await drain()
        XCTAssertEqual(speaker.spoken, ["line1"], "stale completion never reactivates output")
        XCTAssertEqual(leasing.acquires, 1)
        XCTAssertEqual(leasing.releases.values.first, 1, "still exactly one release")
        // Explicit engage still works afterwards.
        binding.engage(generation: 1, backlogThroughSeq: nil, owner: .none)
        binding.ingest(lines([4], from: 300), generation: 1, owner: .none)
        await drain()
        XCTAssertEqual(speaker.spoken, ["line1", "line4"])
        XCTAssertEqual(leasing.acquires, 2)
    }

    func testStopBeforeDeadlinesCancelsThemAndLateTimersAreInert() async {
        let (binding, _, leasing, speaker) = make()
        binding.engage(generation: 1, backlogThroughSeq: nil, owner: .none)
        binding.ingest(lines([1]), generation: 1, owner: .none)
        await drain()
        binding.stop(generation: 1); await drain()
        XCTAssertEqual(clock.pending, 0, "deadlines cancelled with the line")
        let stopsAfterStop = speaker.stops
        clock.advance(.seconds(120)); await drain()
        XCTAssertEqual(speaker.stops, stopsAfterStop)
        XCTAssertEqual(leasing.releases.values.reduce(0, +), 1)
    }

    func testHardDeadlineOfOldGenerationCannotTouchNewRoom() async {
        let leasing = FakeLeasing(), speaker = NoncooperativeSpeaker(), sink = RecordingSink()
        let executor = LAAChairedVoiceEffectExecutor(
            leasing: leasing, speaker: speaker, audioOwner: { .none },
            timer: { [unowned self] in self.clock.timer($0, $1) },
            schedule: { [unowned self] in self.queued.append($0) })
        executor.sink = sink
        executor.perform(.speak(utterance(1), ticket: 1), generation: 1)
        clock.advance(.seconds(50))
        executor.perform(.speak(utterance(2), ticket: 2), generation: 2)
        clock.advance(.seconds(25)) // gen-1 hard time; gen-2 at 25 s
        await drain()
        XCTAssertEqual(leasing.held.count, 1, "new room keeps its lease")
        XCTAssertTrue(executor.isSpeaking)
        XCTAssertEqual(sink.log, [])
        clock.advance(.seconds(50)); await drain() // gen-2 hard
        XCTAssertTrue(leasing.held.isEmpty)
        XCTAssertEqual(sink.log, ["stop g2"])
        XCTAssertTrue(leasing.releases.values.allSatisfy { $0 == 1 })
        speaker.lateFinish(); await drain()
        XCTAssertEqual(sink.log, ["stop g2"])
    }

    func testRoomChangeTearsDownAndOldCompletionIsIgnored() async {
        let (binding, executor, leasing, speaker) = make()
        binding.engage(generation: 1, backlogThroughSeq: nil, owner: .none)
        binding.ingest(lines([1, 2]), generation: 1, owner: .none)
        await drain()
        binding.bind(roomID: "room-y", generation: 2)
        executor.roomChanged(generation: 2)
        await drain()
        XCTAssertTrue(leasing.held.isEmpty)
        XCTAssertGreaterThanOrEqual(speaker.stops, 1)
        binding.completed(ticket: 1, generation: 1)
        await drain()
        XCTAssertEqual(speaker.spoken, ["line1"])
        XCTAssertEqual(leasing.acquires, 1)
    }

    func testCallStartingBeforeSpeakIsNotPreempted() async {
        let (binding, _, leasing, speaker) = make()
        binding.engage(generation: 1, backlogThroughSeq: nil, owner: .none)
        owner = .staffCall // call began after engage, before the line arrives
        binding.ingest(lines([1]), generation: 1, owner: .none)
        await drain()
        XCTAssertEqual(leasing.acquires, 0)
        XCTAssertEqual(speaker.spoken, [])
        XCTAssertEqual(binding.core.phase, .silent, "binding yielded")
    }

    func testTakeoverStopsAndDisengages() async {
        let (binding, _, leasing, speaker) = make()
        binding.engage(generation: 1, backlogThroughSeq: nil, owner: .none)
        binding.ingest(lines([1, 2]), generation: 1, owner: .none)
        await drain()
        leasing.takeover?()
        await drain()
        XCTAssertTrue(leasing.held.isEmpty)
        XCTAssertEqual(binding.core.phase, .silent)
        XCTAssertEqual(speaker.spoken, ["line1"])
    }

    func testAcquireFailureDisengagesWithoutRetryLoop() async {
        let (binding, _, leasing, speaker) = make()
        leasing.failNext = true
        binding.engage(generation: 1, backlogThroughSeq: nil, owner: .none)
        binding.ingest(lines([1, 2]), generation: 1, owner: .none)
        await drain()
        XCTAssertEqual(speaker.spoken, [])
        XCTAssertTrue(leasing.held.isEmpty)
        XCTAssertEqual(binding.core.phase, .silent)
    }

    private final class RecordingSink: LAAChairedVoiceEffectSink {
        var log: [String] = []
        func completed(ticket: UInt64, generation: Int) { log.append("completed \(ticket) g\(generation)") }
        func stop(generation: Int) { log.append("stop g\(generation)") }
        func audioOwnerChanged(_ owner: LAAChairedVoiceAudioOwner, generation: Int) { log.append("owner g\(generation)") }
    }

    /// Speaker whose stop() does not end speak(): a line that finishes
    /// normally after Stop must still be dropped by the executor.
    private final class StubbornSpeaker: LAAChairedVoiceSpeaking {
        var pending: [CheckedContinuation<Void, Error>] = []
        func speak(text: String, speakerID: String) async throws { try await withCheckedThrowingContinuation { pending.append($0) } }
        func stop() {}
    }

    private func utterance(_ seq: Int) -> LAAChairedVoiceUtterance {
        LAAChairedVoiceUtterance(roomID: room, seq: seq, eventID: "m\(seq)", speakerID: "hortensia", text: "line\(seq)")
    }

    func testExecutorDropsCompletionThatArrivesAfterStop() async {
        let leasing = FakeLeasing(), speaker = StubbornSpeaker(), sink = RecordingSink()
        let executor = LAAChairedVoiceEffectExecutor(leasing: leasing, speaker: speaker, audioOwner: { .none },
                                                     timer: { [unowned self] in self.clock.timer($0, $1) },
                                                     schedule: { [unowned self] in self.queued.append($0) })
        executor.sink = sink
        executor.perform(.speak(utterance(1), ticket: 1), generation: 1)
        await drain()
        executor.perform(.stopSpeaking(ticket: 1), generation: 1)
        executor.perform(.releaseAudio, generation: 1)
        speaker.pending.forEach { $0.resume() }; speaker.pending = []
        await drain()
        XCTAssertEqual(sink.log, [], "stale completion is not reported")
        XCTAssertTrue(leasing.held.isEmpty)
    }

    func testNewerGenerationNeverReusesOldLease() async {
        let leasing = FakeLeasing(), speaker = FakeSpeaker(), sink = RecordingSink()
        let executor = LAAChairedVoiceEffectExecutor(leasing: leasing, speaker: speaker, audioOwner: { .none },
                                                     timer: { [unowned self] in self.clock.timer($0, $1) },
                                                     schedule: { [unowned self] in self.queued.append($0) })
        executor.sink = sink
        executor.perform(.speak(utterance(1), ticket: 1), generation: 1)
        await drain()
        executor.perform(.speak(utterance(2), ticket: 2), generation: 2)
        await drain()
        XCTAssertEqual(leasing.acquires, 2, "old room's lease torn down, new one acquired")
        XCTAssertEqual(leasing.held.count, 1)
        leasing.takeover?()
        await drain()
        XCTAssertEqual(sink.log, ["stop g2"], "takeover reaches the current room only")
        XCTAssertTrue(leasing.held.isEmpty)
        executor.perform(.speak(utterance(3), ticket: 3), generation: 1)
        XCTAssertEqual(leasing.acquires, 2, "older generation cannot start audio")
    }
}
#endif
