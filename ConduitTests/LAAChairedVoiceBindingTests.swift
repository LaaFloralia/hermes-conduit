#if LAA_BUILD
import XCTest
@testable import Conduit

/// Real `GroupEvent` shapes (sanitized, synthetic ids), a recording fake
/// effect handler; no audio, no coordinator, no network.
@MainActor
final class LAAChairedVoiceBindingTests: XCTestCase {
    private final class Recorder: LAAChairedVoiceEffectHandling {
        var log: [(LAAChairedVoiceEffect, Int)] = []
        func perform(_ effect: LAAChairedVoiceEffect, generation: Int) { log.append((effect, generation)) }
        var spoken: [String] { log.compactMap { if case let .speak(l, _) = $0.0 { return l.eventID } else { return nil } } }
        var lastTicket: UInt64? { log.reversed().lazy.compactMap { if case let .speak(_, t) = $0.0 { return t } else { return nil } }.first }
        var effects: [LAAChairedVoiceEffect] { log.map(\.0) }
    }

    private let room = "room-x"

    private func actor(_ kind: String, _ id: String) -> GroupActor {
        GroupActor(kind: kind, id: id, profile: kind == "member" ? id : nil, displayName: nil, connectionID: nil)
    }

    private func event(_ seq: Int, _ kind: String, id: String, actor: GroupActor, payload: [String: AnyCodable] = [:], room: String? = nil) -> GroupEvent {
        GroupEvent(roomID: room ?? self.room, seq: seq, eventID: id, kind: kind, actor: actor,
                   authorityEpoch: 1, payload: payload, createdAt: Double(seq))
    }

    private func user(_ seq: Int, _ text: String) -> GroupEvent {
        event(seq, "message.user", id: "u\(seq)", actor: actor("user", "owner"), payload: ["text": .string(text), "thread_id": .string("t")])
    }

    private func memberMsg(_ seq: Int, _ text: String, staff: String = "hortensia") -> GroupEvent {
        event(seq, "message.member", id: "m\(seq)", actor: actor("member", staff), payload: ["text": .string(text), "thread_id": .string("t")])
    }

    private func settled(_ seq: Int, message: String) -> GroupEvent {
        event(seq, "turn.settled", id: "s\(seq)", actor: actor("gateway", "gw"),
              payload: ["message_event_id": .string(message), "member_id": .string("hortensia"), "round_index": .number(0)])
    }

    private func started(_ seq: Int) -> GroupEvent {
        event(seq, "turn.started", id: "ts\(seq)", actor: actor("gateway", "gw"), payload: ["member_id": .string("hortensia")])
    }

    private func make(generation: Int = 1) -> (LAAChairedVoiceBinding, Recorder) {
        let recorder = Recorder()
        let binding = LAAChairedVoiceBinding(handler: recorder)
        binding.bind(roomID: room, generation: generation)
        return (binding, recorder)
    }

    func testAdapterFinalizesOnlySettledMemberMessages() {
        let events = [user(1, "hi"), started(2), memberMsg(3, "answer"), memberMsg(4, "draft"), settled(5, message: "m3")]
        let mapped = LAAChairedVoiceBinding.voiceEvents(events)
        XCTAssertEqual(mapped.map(\.eventID), ["m3", "m4"], "only message.member rows")
        XCTAssertEqual(mapped.map(\.isFinal), [true, false])
        XCTAssertEqual(mapped.first?.speakerID, "hortensia")
        XCTAssertEqual(mapped.first?.text, "answer")
    }

    func testFinalizationArrivesInLaterPollThenSpeaksOnce() {
        let (binding, rec) = make()
        var log = [user(1, "q")]
        binding.ingest(log, generation: 1, owner: .none)
        XCTAssertNil(binding.engage(generation: 1, backlogThroughSeq: log.last?.seq, owner: .none))
        log += [started(2), memberMsg(3, "reply")]
        binding.ingest(log, generation: 1, owner: .none)
        XCTAssertEqual(rec.spoken, [], "unsettled member message is not spoken")
        log.append(settled(4, message: "m3"))
        binding.ingest(log, generation: 1, owner: .none)
        XCTAssertEqual(rec.spoken, ["m3"])
        binding.ingest(log, generation: 1, owner: .none)
        XCTAssertEqual(rec.spoken, ["m3"], "re-fed poll replay is deduped")
    }

    func testInitialTailBacklogStaysSilentAfterEngage() {
        let (binding, rec) = make()
        let tail = [user(1, "q"), memberMsg(2, "old"), settled(3, message: "m2")]
        binding.ingest(tail, generation: 1, owner: .none)
        binding.engage(generation: 1, backlogThroughSeq: tail.last?.seq, owner: .none)
        binding.ingest(tail, generation: 1, owner: .none)
        XCTAssertEqual(rec.log.count, 0, "nothing at open or engage")
    }

    func testReconnectResyncReplacesReplayWithoutRepeating() throws {
        let (binding, rec) = make()
        binding.engage(generation: 1, backlogThroughSeq: 0, owner: .none)
        let before = [memberMsg(1, "a"), settled(2, message: "m1")]
        binding.ingest(before, generation: 1, owner: .none)
        XCTAssertEqual(rec.spoken, ["m1"])
        binding.completed(ticket: try XCTUnwrap(rec.lastTicket), generation: 1)
        // replaceAll after a gap: authoritative tail overlapping what was spoken.
        let resynced = before + [memberMsg(5, "b"), settled(6, message: "m5")]
        binding.ingest(resynced, generation: 1, owner: .none)
        XCTAssertEqual(rec.spoken, ["m1", "m5"])
    }

    func testStaleGenerationEffectsAndCompletionsAreIgnored() throws {
        let (binding, rec) = make(generation: 1)
        binding.engage(generation: 1, backlogThroughSeq: 0, owner: .none)
        binding.ingest([memberMsg(1, "a"), settled(2, message: "m1")], generation: 1, owner: .none)
        let oldTicket = try XCTUnwrap(rec.lastTicket)
        binding.bind(roomID: "room-y", generation: 2)
        XCTAssertEqual(rec.effects.suffix(2), [.stopSpeaking(ticket: oldTicket), .releaseAudio])
        let count = rec.log.count
        binding.completed(ticket: oldTicket, generation: 1)
        binding.ingest([memberMsg(3, "late"), settled(4, message: "m3")], generation: 1, owner: .none)
        binding.unbind(generation: 1)
        XCTAssertEqual(rec.log.count, count, "old room's poll, completion, teardown are no-ops")
        XCTAssertEqual(binding.engage(generation: 1, backlogThroughSeq: nil, owner: .none), .notBound)
    }

    func testStaffCallRefusesEngageWithoutAnyEffect() {
        let (binding, rec) = make()
        XCTAssertEqual(binding.engage(generation: 1, backlogThroughSeq: 0, owner: .staffCall), .staffCallOwnsAudio)
        binding.ingest([memberMsg(1, "a"), settled(2, message: "m1")], generation: 1, owner: .staffCall)
        XCTAssertEqual(rec.log.count, 0, "no speak, no lease, no takeover")
        XCTAssertEqual(binding.core.phase, .silent)
    }

    func testStaffCallStartingStopsMeetingAndNeedsExplicitReengage() throws {
        let (binding, rec) = make()
        binding.engage(generation: 1, backlogThroughSeq: 0, owner: .none)
        binding.ingest([memberMsg(1, "a"), settled(2, message: "m1")], generation: 1, owner: .none)
        let t = try XCTUnwrap(rec.lastTicket)
        binding.audioOwnerChanged(.staffCall, generation: 1)
        XCTAssertEqual(rec.effects.suffix(2), [.stopSpeaking(ticket: t), .releaseAudio])
        binding.ingest([memberMsg(3, "b"), settled(4, message: "m3")], generation: 1, owner: .none)
        XCTAssertEqual(rec.spoken, ["m1"], "call ending does not reactivate meeting audio")
        binding.engage(generation: 1, backlogThroughSeq: nil, owner: .none)
        binding.ingest([memberMsg(5, "c"), settled(6, message: "m5")], generation: 1, owner: .none)
        XCTAssertEqual(rec.spoken, ["m1", "m5"])
    }

    func testIngestDuringStaffCallStopsEngagedRoom() throws {
        let (binding, rec) = make()
        binding.engage(generation: 1, backlogThroughSeq: 0, owner: .none)
        binding.ingest([memberMsg(1, "a"), settled(2, message: "m1")], generation: 1, owner: .none)
        let t = try XCTUnwrap(rec.lastTicket)
        binding.ingest([memberMsg(3, "b"), settled(4, message: "m3")], generation: 1, owner: .staffCall)
        XCTAssertEqual(rec.spoken, ["m1"])
        XCTAssertEqual(rec.effects.suffix(2), [.stopSpeaking(ticket: t), .releaseAudio])
    }

    func testWithoutHandlerNothingIsPerformedAndNoEngageImplied() {
        let binding = LAAChairedVoiceBinding()
        binding.bind(roomID: room, generation: 1)
        binding.ingest([memberMsg(1, "a"), settled(2, message: "m1")], generation: 1, owner: .none)
        XCTAssertEqual(binding.core.phase, .silent)
        XCTAssertNil(binding.core.current)
    }

    func testForeignRoomEventsInPageAreIgnored() {
        let (binding, rec) = make()
        binding.engage(generation: 1, backlogThroughSeq: 0, owner: .none)
        let foreign = event(1, "message.member", id: "f1", actor: actor("member", "x"), payload: ["text": .string("t")], room: "other")
        let foreignSettle = event(2, "turn.settled", id: "fs", actor: actor("gateway", "gw"), payload: ["message_event_id": .string("f1")], room: "other")
        binding.ingest([foreign, foreignSettle], generation: 1, owner: .none)
        XCTAssertEqual(rec.log.count, 0)
    }

    // MARK: - M1/M2 synthetic regressions (T1/T2)

    /// M1 rule as the app computes it while the owner talks through the room composer.
    private func yieldOwner(_ b: LAAChairedVoiceBinding, voiceInUse: Bool = false, nativeCall: Bool = false) -> LAAChairedVoiceAudioOwner {
        AppState.chairedVoiceYieldOwner(ownerTalking: b.core.phase == .ownerTalking,
                                        nativeCall: nativeCall, conversationPolicy: true, voiceInUse: voiceInUse)
    }

    func testOwnDictationCaptureDoesNotStopTalkingRoomOnIngest() {
        let (binding, rec) = make()
        binding.engage(generation: 1, backlogThroughSeq: 0, owner: .none)
        binding.talk(generation: 1)
        binding.ingest([memberMsg(1, "a"), settled(2, message: "m1")], generation: 1, owner: yieldOwner(binding))
        XCTAssertEqual(binding.core.phase, .ownerTalking)
        XCTAssertEqual(rec.spoken, [])
        binding.talkEnded(generation: 1)
        XCTAssertEqual(rec.spoken, ["m1"], "line held during own dictation speaks after send")
    }

    func testStaffVoiceDuringTalkStillStopsRoom() {
        let (binding, _) = make()
        binding.engage(generation: 1, backlogThroughSeq: 0, owner: .none)
        binding.talk(generation: 1)
        binding.ingest([memberMsg(1, "a"), settled(2, message: "m1")], generation: 1, owner: yieldOwner(binding, voiceInUse: true))
        XCTAssertEqual(binding.core.phase, .silent)
    }

    func testNativeCallDuringTalkStillStopsRoom() {
        let (binding, _) = make()
        binding.engage(generation: 1, backlogThroughSeq: 0, owner: .none)
        binding.talk(generation: 1)
        binding.audioOwnerChanged(yieldOwner(binding, nativeCall: true), generation: 1)
        XCTAssertEqual(binding.core.phase, .silent)
    }

    func testYieldOwnerIsStrictOutsideTalk() {
        XCTAssertEqual(AppState.chairedVoiceYieldOwner(ownerTalking: false, nativeCall: false, conversationPolicy: true, voiceInUse: false), .staffCall)
        XCTAssertEqual(AppState.chairedVoiceYieldOwner(ownerTalking: true, nativeCall: false, conversationPolicy: true, voiceInUse: false), .none)
        XCTAssertEqual(AppState.chairedVoiceYieldOwner(ownerTalking: true, nativeCall: false, conversationPolicy: false, voiceInUse: true), .staffCall)
    }
}
#endif
