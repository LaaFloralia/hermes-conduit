#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAAMeetingVoiceTests: XCTestCase {
    func testPureTurnLifecycleAndInterrupt() {
        var turn = LAAMeetingTurn()
        turn.apply(.messageComplete(total: 3))
        XCTAssertEqual(turn.phase, .idle)
        turn.apply(.join)
        XCTAssertEqual(turn.phase, .listening)
        turn.apply(.tapTalk)
        XCTAssertTrue(turn.ownerTalking)
        turn.apply(.messageComplete(total: 1))
        XCTAssertEqual(turn.phase, .listening)
        turn.apply(.vadEnd)
        XCTAssertEqual(turn.phase, .sending)
        turn.apply(.sendRegistered)
        XCTAssertEqual(turn.phase, .waiting)
        turn.apply(.messageComplete(total: 2))
        XCTAssertEqual(turn.phase, .speaking(index: 1, total: 2))
        turn.apply(.ttsFinished(remaining: 1))
        XCTAssertEqual(turn.phase, .speaking(index: 2, total: 2))
        turn.apply(.bargeIn)
        XCTAssertTrue(turn.ownerTalking)
        turn.apply(.ttsFinished(remaining: 0))
        XCTAssertEqual(turn.phase, .listening)
        turn.apply(.vadEnd)
        turn.apply(.sendRegistered)
        turn.apply(.timeout)
        XCTAssertEqual(turn.phase, .listening)
        turn.apply(.leave)
        XCTAssertEqual(turn.phase, .idle)
    }

    func testRoundCloseDoesNotDiscardAnEditableDraft() {
        var turn = LAAMeetingTurn()
        turn.apply(.join)
        turn.apply(.tapTalk)
        turn.apply(.vadEnd)
        turn.apply(.roundClosed)
        XCTAssertEqual(turn.phase, .sending)
        turn.apply(.sendRegistered)
        turn.apply(.roundClosed)
        XCTAssertEqual(turn.phase, .listening)
    }

    func testExcerptCapsLengthAndSpokenSentences() {
        XCTAssertEqual(LAAMeetingTurn.spokenExcerpt("一文です。二文です！三文です。"), "一文です。二文です！")
        XCTAssertEqual(LAAMeetingTurn.spokenExcerpt(String(repeating: "長", count: 310)).count, 240)
        XCTAssertEqual(LAAMeetingTurn.spokenExcerpt("確認します。\n\n詳細：録音に含めない。"), "確認します。")
        XCTAssertEqual(LAAMeetingTurn.spokenExcerpt("Version 1.2. Done! Omitted."), "Version 1.2. Done!")
    }

    @MainActor
    func testRegisteredRoundUsesServerDiscussionID() {
        let meeting = LAAMeetingSession()
        meeting.apply(.join)
        meeting.registerRound(clientEventID: "hello")
        XCTAssertEqual(meeting.roundID, "user:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(meeting.turn.phase, .waiting)
        meeting.apply(.leave)
        XCTAssertNil(meeting.roundID)
    }

    func testVADRequiresSustainedSpeechThenAQuietTail() {
        var vad = LAAMeetingVAD()
        XCTAssertFalse(vad.observe(level: 0, at: .zero))
        XCTAssertFalse(vad.observe(level: 0.12, at: .milliseconds(200)))
        XCTAssertFalse(vad.observe(level: 0, at: .milliseconds(280)))
        XCTAssertFalse(vad.observe(level: 0, at: .seconds(2))) // Tap noise is too short.
        XCTAssertFalse(vad.observe(level: 0.10, at: .milliseconds(2100)))
        XCTAssertFalse(vad.observe(level: 0.08, at: .milliseconds(2250)))
        XCTAssertFalse(vad.observe(level: 0, at: .milliseconds(2300)))
        XCTAssertFalse(vad.observe(level: 0, at: .milliseconds(3499)))
        XCTAssertTrue(vad.observe(level: 0, at: .milliseconds(3500)))
        XCTAssertFalse(vad.observe(level: 0, at: .seconds(4)))
    }

    func testSkipMuteAndSequenceDeduplication() {
        var playback = LAAChairedVoicePlayback()
        func event(_ seq: Int, _ id: String) -> LAAChairedVoiceEvent {
            .init(roomID: "meeting", seq: seq, eventID: id, actorKind: "member", speakerID: "staff", text: "Reply", isFinal: true)
        }
        playback.bind(roomID: "meeting", generation: 1)
        playback.engage(generation: 1, backlogThroughSeq: 0)
        playback.receive(event(1, "first"), generation: 1)
        let first = playback.current?.ticket
        playback.receive(event(2, "second"), generation: 1)
        playback.receive(event(2, "malformed-duplicate"), generation: 1)
        XCTAssertEqual(playback.queue.count, 1)
        playback.skip(generation: 1)
        XCTAssertEqual(playback.current?.utterance.seq, 2)
        XCTAssertTrue(playback.completed(ticket: first ?? 0, generation: 1).isEmpty)
        playback.toggleMute(generation: 1)
        XCTAssertNil(playback.current)
        playback.receive(event(3, "while-muted"), generation: 1)
        playback.toggleMute(generation: 1)
        XCTAssertTrue(playback.receive(event(3, "while-muted"), generation: 1).isEmpty)
        XCTAssertFalse(playback.receive(event(4, "later"), generation: 1).isEmpty)
    }

    @MainActor
    func testLocalDeadlineStopsBeforeServerLeaseExpires() async throws {
        let endpoint = LAAMeetingEndpoint()
        let lost = expectation(description: "conservative local deadline")
        endpoint.onLoss = { lost.fulfill() }
        let client = LAAMeetingLeaseClient { room, request in
            guard request.action == "claim" else { return nil }
            return .init(roomId: room, endpointId: request.endpointId, generation: "first", expiresAt: 12000, remainingMs: 700)
        }
        let claimed = try await endpoint.claim(room: "room", using: client)
        XCTAssertTrue(claimed)
        await fulfillment(of: [lost], timeout: 3)
        XCTAssertFalse(endpoint.canUseAudio)
        XCTAssertNil(endpoint.generation)
    }

    @MainActor
    func testLateClaimAfterLeaveCannotAuthorizeButIsReleased() async throws {
        let endpoint = LAAMeetingEndpoint()
        var continuation: CheckedContinuation<LAAMeetingGrant, Never>?
        var sent: LAAMeetingLeaseClient.Request?
        var released: String?
        let client = LAAMeetingLeaseClient { _, request in
            if request.action == "release" { released = request.generation; return nil }
            sent = request
            return await withCheckedContinuation { continuation = $0 }
        }
        let claim = Task { try await endpoint.claim(room: "room", using: client) }
        while continuation == nil { await Task.yield() }
        XCTAssertFalse(endpoint.canUseAudio)
        endpoint.leave()
        continuation?.resume(returning: .init(roomId: "room", endpointId: try XCTUnwrap(sent?.endpointId),
                                              generation: "stale", expiresAt: 12000, remainingMs: 12000))
        let claimed = try await claim.value
        XCTAssertFalse(claimed)
        XCTAssertFalse(endpoint.canUseAudio)
        for _ in 0..<20 where released == nil { await Task.yield() }
        XCTAssertEqual(released, "stale")
    }
}
#endif
