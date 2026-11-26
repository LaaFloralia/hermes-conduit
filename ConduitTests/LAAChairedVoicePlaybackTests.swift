#if LAA_BUILD
import XCTest
@testable import Conduit

/// Chaired-room Voice core: sanitized synthetic events only, no audio,
/// no session coordinator, no network.
final class LAAChairedVoicePlaybackTests: XCTestCase {
    private let room = "room-a"

    private func member(_ seq: Int, _ text: String = "line", id: String? = nil,
                        room: String? = nil, final: Bool = true, kind: String = "member",
                        speaker: String = "staff-1") -> LAAChairedVoiceEvent {
        LAAChairedVoiceEvent(roomID: room ?? self.room, seq: seq, eventID: id ?? "e\(seq)",
                             actorKind: kind, speakerID: speaker, text: text, isFinal: final)
    }

    private func engaged(generation: Int = 1, backlog: Int? = nil) -> LAAChairedVoicePlayback {
        var voice = LAAChairedVoicePlayback()
        voice.bind(roomID: room, generation: generation)
        voice.engage(generation: generation, backlogThroughSeq: backlog)
        return voice
    }

    private func spoken(_ effects: [LAAChairedVoiceEffect]) -> [String] {
        effects.compactMap { if case let .speak(line, _) = $0 { return line.eventID } else { return nil } }
    }

    private func ticket(_ effects: [LAAChairedVoiceEffect]) -> UInt64? {
        effects.lazy.compactMap { if case let .speak(_, ticket) = $0 { return ticket } else { return nil } }.first
    }

    func testSpeaksFinalizedStaffLinesSeriallyInSeqOrder() throws {
        var voice = engaged()
        let first = voice.receive(member(2), generation: 1)
        XCTAssertEqual(spoken(first), ["e2"])
        XCTAssertEqual(spoken(voice.receive(member(4), generation: 1)), [], "one line at a time")
        XCTAssertEqual(spoken(voice.receive(member(3), generation: 1)), [])
        XCTAssertEqual(voice.queue.map(\.seq), [3, 4], "queued in seq order")
        let second = voice.completed(ticket: try XCTUnwrap(ticket(first)), generation: 1)
        XCTAssertEqual(spoken(second), ["e3"])
        let third = voice.completed(ticket: try XCTUnwrap(ticket(second)), generation: 1)
        XCTAssertEqual(spoken(third), ["e4"])
        XCTAssertEqual(voice.completed(ticket: try XCTUnwrap(ticket(third)), generation: 1), [.releaseAudio])
    }

    func testIgnoresNonFinalUserNonMemberAndBlankLines() {
        var voice = engaged()
        XCTAssertEqual(voice.receive(member(1, final: false), generation: 1), [])
        XCTAssertEqual(voice.receive(member(2, kind: "user"), generation: 1), [])
        XCTAssertEqual(voice.receive(member(3, kind: "system"), generation: 1), [])
        XCTAssertEqual(voice.receive(member(4, "  \n "), generation: 1), [])
        XCTAssertEqual(voice.receive(member(5, id: ""), generation: 1), [])
        XCTAssertNil(voice.current)
    }

    func testStreamingPreviewDoesNotBlockItsFinalLine() {
        var voice = engaged()
        XCTAssertEqual(voice.receive(member(7, "par", id: "m7", final: false), generation: 1), [])
        XCTAssertEqual(spoken(voice.receive(member(7, "partial done", id: "m7"), generation: 1)), ["m7"])
        XCTAssertEqual(voice.current?.utterance.text, "partial done")
    }

    func testSameEventLiveAndReplayedSpeaksOnce() throws {
        var voice = engaged()
        let first = voice.receive(member(2), generation: 1)
        XCTAssertEqual(voice.receive(member(2), generation: 1), [], "replay of the playing line")
        XCTAssertEqual(voice.completed(ticket: try XCTUnwrap(ticket(first)), generation: 1), [.releaseAudio])
        XCTAssertEqual(voice.receive(member(2), generation: 1), [], "replay after it finished")
    }

    func testDoubleCompletionDoesNotAdvanceTwice() throws {
        var voice = engaged()
        let first = voice.receive(member(1), generation: 1)
        voice.receive(member(2), generation: 1)
        voice.receive(member(3), generation: 1)
        let t = try XCTUnwrap(ticket(first))
        XCTAssertEqual(spoken(voice.completed(ticket: t, generation: 1)), ["e2"])
        XCTAssertEqual(voice.completed(ticket: t, generation: 1), [], "duplicate completion is stale")
        XCTAssertEqual(voice.current?.utterance.eventID, "e2")
    }

    func testSilentUntilEngagedAndBacklogStaysSilent() {
        var voice = LAAChairedVoicePlayback()
        voice.bind(roomID: room, generation: 1)
        XCTAssertEqual(voice.receive(member(1), generation: 1), [], "observer / launch: silent")
        XCTAssertEqual(voice.receive(member(2), generation: 1), [])
        voice.engage(generation: 1, backlogThroughSeq: 5)
        XCTAssertEqual(voice.receive(member(2), generation: 1), [], "already heard")
        XCTAssertEqual(voice.receive(member(4, id: "late-backlog"), generation: 1), [], "within backlog")
        XCTAssertEqual(spoken(voice.receive(member(6), generation: 1)), ["e6"])
    }

    func testEngageWithoutBacklogUsesHighestSeqSeen() {
        var voice = LAAChairedVoicePlayback()
        voice.bind(roomID: room, generation: 1)
        voice.receive(member(9), generation: 1)
        voice.engage(generation: 1)
        XCTAssertEqual(voice.receive(member(8, id: "older"), generation: 1), [])
        XCTAssertEqual(spoken(voice.receive(member(10), generation: 1)), ["e10"])
    }

    func testTalkFlushesStopsAndInvalidatesCompletion() throws {
        var voice = engaged()
        let first = voice.receive(member(1), generation: 1)
        voice.receive(member(2), generation: 1)
        let t = try XCTUnwrap(ticket(first))
        XCTAssertEqual(voice.talk(generation: 1), [.stopSpeaking(ticket: t), .releaseAudio])
        XCTAssertEqual(voice.queue, [])
        XCTAssertEqual(voice.completed(ticket: t, generation: 1), [], "stale completion after barge-in")
        XCTAssertEqual(voice.receive(member(2), generation: 1), [], "flushed lines never come back")
        XCTAssertEqual(voice.phase, .ownerTalking)
    }

    func testLinesDuringTalkWaitForTalkEnded() {
        var voice = engaged()
        voice.talk(generation: 1)
        XCTAssertEqual(voice.receive(member(5), generation: 1), [], "never over the owner")
        XCTAssertEqual(spoken(voice.talkEnded(generation: 1)), ["e5"])
    }

    func testStopFlushesAndDisengages() throws {
        var voice = engaged()
        let first = voice.receive(member(1), generation: 1)
        voice.receive(member(2), generation: 1)
        let t = try XCTUnwrap(ticket(first))
        XCTAssertEqual(voice.stop(generation: 1), [.stopSpeaking(ticket: t), .releaseAudio])
        XCTAssertEqual(voice.completed(ticket: t, generation: 1), [])
        XCTAssertEqual(voice.receive(member(3), generation: 1), [], "silent after Stop")
        voice.engage(generation: 1)
        XCTAssertEqual(voice.receive(member(2), generation: 1), [], "flushed line stays unspoken")
        XCTAssertEqual(spoken(voice.receive(member(4), generation: 1)), ["e4"])
    }

    func testStopWhileIdleEmitsNothing() {
        var voice = engaged()
        XCTAssertEqual(voice.stop(generation: 1), [])
        XCTAssertEqual(voice.talk(generation: 1), [], "Talk while silent is not a barge-in")
    }

    func testNewerGenerationTakesOverAndOldOwnerIsIgnored() throws {
        var voice = engaged(generation: 1)
        let first = voice.receive(member(1), generation: 1)
        let t = try XCTUnwrap(ticket(first))
        XCTAssertEqual(voice.bind(roomID: "room-b", generation: 2), [.stopSpeaking(ticket: t), .releaseAudio])
        XCTAssertEqual(voice.completed(ticket: t, generation: 1), [])
        XCTAssertEqual(voice.unbind(generation: 1), [], "old room's teardown")
        XCTAssertEqual(voice.stop(generation: 1), [])
        XCTAssertEqual(voice.receive(member(2), generation: 1), [], "old room's late event")
        XCTAssertEqual(voice.bind(roomID: room, generation: 1), [], "older generation cannot rebind")
        XCTAssertEqual(voice.roomID, "room-b")
        voice.engage(generation: 2)
        XCTAssertEqual(voice.receive(member(3), generation: 2), [], "event for another room")
        XCTAssertEqual(spoken(voice.receive(member(3, room: "room-b"), generation: 2)), ["e3"])
    }

    func testSameGenerationRebindIsNoOp() {
        var voice = engaged(generation: 4)
        voice.receive(member(1), generation: 4)
        XCTAssertEqual(voice.bind(roomID: room, generation: 4), [])
        XCTAssertEqual(voice.current?.utterance.eventID, "e1")
    }

    func testStaleBindAfterUnbindIsIgnored() {
        var voice = engaged(generation: 3)
        voice.unbind(generation: 3)
        XCTAssertEqual(voice.bind(roomID: room, generation: 2), [])
        XCTAssertNil(voice.roomID)
        voice.bind(roomID: room, generation: 4)
        XCTAssertEqual(voice.roomID, room)
    }

    func testCompletionOfFinalLineDuringTalkDoesNotRestart() throws {
        var voice = engaged()
        let first = voice.receive(member(1), generation: 1)
        voice.talk(generation: 1)
        voice.receive(member(2), generation: 1)
        XCTAssertEqual(voice.completed(ticket: try XCTUnwrap(ticket(first)), generation: 1), [])
        XCTAssertNil(voice.current)
    }

    func testHeardLimitStillPreventsReplayThroughSeqFloor() {
        var voice = engaged()
        voice.talk(generation: 1)
        let total = LAAChairedVoicePlayback.heardLimit + 10
        for seq in 1...total { voice.receive(member(seq), generation: 1) }
        voice.stop(generation: 1)
        voice.engage(generation: 1)
        XCTAssertEqual(voice.receive(member(1), generation: 1), [], "id evicted, seq floor holds")
        XCTAssertEqual(spoken(voice.receive(member(total + 1), generation: 1)), ["e\(total + 1)"])
    }
}
#endif
