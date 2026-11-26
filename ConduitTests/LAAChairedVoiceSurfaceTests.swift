#if LAA_BUILD
import XCTest
@testable import Conduit

/// The Voice bar's state derivation and its 1:1 mapping onto the real
/// `LAAChairedVoiceBinding`. A recording handler stands in for the AppState
/// executor; no audio, no microphone, no view hosting.
@MainActor
final class LAAChairedVoiceSurfaceTests: XCTestCase {
    private final class Recorder: LAAChairedVoiceEffectHandling {
        var effects: [LAAChairedVoiceEffect] = []
        func perform(_ effect: LAAChairedVoiceEffect, generation: Int) { effects.append(effect) }
        var spoken: [String] { effects.compactMap { if case let .speak(l, _) = $0 { return l.eventID } else { return nil } } }
    }

    private let room = "room-x"

    private func member(_ seq: Int) -> GroupEvent {
        GroupEvent(roomID: room, seq: seq, eventID: "m\(seq)", kind: "message.member",
                   actor: GroupActor(kind: "member", id: "hortensia", profile: "hortensia", displayName: nil, connectionID: nil),
                   authorityEpoch: 1, payload: ["text": .string("line \(seq)"), "thread_id": .string("t")], createdAt: Double(seq))
    }

    private func settled(_ seq: Int, _ message: String) -> GroupEvent {
        GroupEvent(roomID: room, seq: seq, eventID: "s\(seq)", kind: "turn.settled",
                   actor: GroupActor(kind: "gateway", id: "gw", profile: nil, displayName: nil, connectionID: nil),
                   authorityEpoch: 1, payload: ["message_event_id": .string(message)], createdAt: Double(seq))
    }

    private func state(_ b: LAAChairedVoiceBinding, room: String? = "room-x",
                       owner: LAAChairedVoiceAudioOwner = .none, wired: Bool = true) -> LAAChairedVoiceSurfaceState {
        .make(roomID: room, boundRoomID: b.core.roomID, phase: b.core.phase, owner: owner, playbackWired: wired)
    }

    // MARK: Visibility

    func testHiddenUnlessThisChairedRoomIsBoundAndPlaybackWired() {
        let b = LAAChairedVoiceBinding()
        XCTAssertEqual(state(b), .hidden, "unbound (not a 壁打ち room)")
        b.bind(roomID: room, generation: 1)
        XCTAssertEqual(state(b), .off)
        XCTAssertEqual(state(b, room: "other"), .hidden, "binding of another room")
        XCTAssertEqual(state(b, room: nil), .hidden, "no room on screen")
        XCTAssertEqual(state(b, wired: false), .hidden, "no executor: no button that plays nothing")
        XCTAssertEqual(LAAChairedVoiceSurface.playbackWired, true, "enabled after the meeting gates passed (Wave 3)")
        b.leaveRoom()
        XCTAssertEqual(state(b), .hidden, "left / non-chaired room")
    }

    // MARK: Silence until explicit input

    func testBindAndIngestStaySilentUntilVoiceTap() {
        let rec = Recorder()
        let b = LAAChairedVoiceBinding(handler: rec)
        b.bind(roomID: room, generation: 1)
        b.ingest([member(1), settled(2, "m1")], generation: 1, owner: .none)
        _ = LAAChairedVoiceActions.binding(b, generation: { 1 }, backlogThroughSeq: { 2 }, owner: { .none })
        XCTAssertEqual(rec.spoken, [], "building the actions performs nothing")
        XCTAssertEqual(state(b), .off)
    }

    // MARK: 1:1 mapping

    func testActionsMapOneToOneOntoBinding() {
        let rec = Recorder()
        let b = LAAChairedVoiceBinding(handler: rec)
        var generation = 1
        var log = [member(1), settled(2, "m1")]
        b.bind(roomID: room, generation: generation)
        b.ingest(log, generation: generation, owner: .none)
        let actions = LAAChairedVoiceActions.binding(
            b, generation: { generation }, backlogThroughSeq: { log.last?.seq }, owner: { .none })

        XCTAssertNil(actions.engage())
        XCTAssertEqual(state(b), .listening)
        XCTAssertEqual(rec.spoken, [], "backlog at the tap stays silent")

        log += [member(3), settled(4, "m3")]
        b.ingest(log, generation: generation, owner: .none)
        XCTAssertEqual(rec.spoken, ["m3"])

        actions.talk()
        XCTAssertEqual(state(b), .talking)
        XCTAssertTrue(rec.effects.contains(.releaseAudio), "Talk releases audio")

        actions.talkEnded()
        XCTAssertEqual(state(b), .listening)

        actions.stop()
        XCTAssertEqual(state(b), .off)

        generation = 2
        XCTAssertEqual(actions.engage(), .notBound, "generation read at tap time; stale room refuses")
    }

    // MARK: Staff call owns audio

    func testStaffCallDisablesAndEngageIsRefusedWithoutEffects() {
        let rec = Recorder()
        let b = LAAChairedVoiceBinding(handler: rec)
        b.bind(roomID: room, generation: 1)
        let actions = LAAChairedVoiceActions.binding(b, generation: { 1 }, backlogThroughSeq: { nil }, owner: { .staffCall })
        XCTAssertEqual(state(b, owner: .staffCall), .staffCallOwnsAudio)
        XCTAssertEqual(actions.engage(), .staffCallOwnsAudio)
        XCTAssertEqual(rec.effects, [], "nothing started")
        XCTAssertEqual(state(b), .off, "still silent after the call")
        XCTAssertFalse(LAAChairedVoiceCopy.refusal(.staffCallOwnsAudio).isEmpty)
    }

    func testInertActionsTouchNothing() {
        XCTAssertNil(LAAChairedVoiceActions.inert.engage())
        LAAChairedVoiceActions.inert.talk()
        LAAChairedVoiceActions.inert.talkEnded()
        LAAChairedVoiceActions.inert.stop()
    }
}
#endif
