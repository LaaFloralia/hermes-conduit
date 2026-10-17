//
//  HermesVoiceGatewayTimeoutTests+LocalLive.swift
//  ConduitTests
//
//  Local Live: a live call through the user's own speech server, with each
//  turn the server asks for run as a Hermes chat turn. The session's wire
//  format and turn frames, the turn runner, and the mode switch.
//  Extensions of existing suites: the CI test planner was at capacity for
//  new XCTestCase classes.
//

import XCTest
@testable import Conduit

@MainActor
final class FakeLocalLiveConnection: LocalLiveConnecting {
    private(set) var requests = 0

    func socketRequest() async throws -> URLRequest {
        requests += 1
        return URLRequest(url: URL(string: "wss://example.com/api/plugins/conduit_push/local-live/socket?ticket=t-\(requests)")!)
    }
}

/// Yields on the main actor until `done` holds, for at most `limit`. A cap,
/// not a timing: it returns as soon as `done` holds.
@MainActor
private func localLiveSettle(until done: () -> Bool, limit: Duration = .seconds(10)) async {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while !done(), ContinuousClock.now < deadline { await Task.yield() }
}

// MARK: - Wire format and session

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    func testLocalLiveSessionUpdateLetsTheServerAnswerEachTurnWithNoTools() throws {
        let update = LocalLiveProtocol.sessionUpdate
        XCTAssertEqual(update["type"] as? String, "session.update")
        let session = try XCTUnwrap(update["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertNil(session["tools"], "the speech server refuses tool_choice; Hermes does the work")
        XCTAssertNil(session["instructions"])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let detection = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        XCTAssertEqual(detection["create_response"] as? Bool, true)
        XCTAssertEqual(detection["interrupt_response"] as? Bool, true)
        XCTAssertEqual((input["format"] as? [String: Any])?["rate"] as? Int, 24_000)
        XCTAssertEqual(((audio["output"] as? [String: Any])?["format"] as? [String: Any])?["rate"] as? Int, 24_000)
    }

    func testLocalLiveReadsOnlyThePluginsTurnFrames() throws {
        func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        XCTAssertEqual(LocalLiveProtocol.turnFrame(try data(["type": "conduit.turn", "turn_id": "t1", "text": "Hi"])), .turn(id: "t1", text: "Hi"))
        XCTAssertEqual(LocalLiveProtocol.turnFrame(try data(["type": "conduit.turn.cancel", "turn_id": "t1"])), .cancel(id: "t1"))
        XCTAssertNil(LocalLiveProtocol.turnFrame(try data(["type": "conduit.turn", "text": "no id"])))
        XCTAssertNil(LocalLiveProtocol.turnFrame(try data(["type": "response.output_audio.delta", "delta": "AAAA"])))
        // The model saying the words is not a turn frame.
        XCTAssertNil(LocalLiveProtocol.turnFrame(try data(["type": "response.output_audio_transcript.delta", "delta": "\"conduit.turn\""])))
    }

    func testLocalLiveSplitsLongRepliesIntoFramesThePluginTakes() {
        XCTAssertEqual(LocalLiveProtocol.deltaChunks(""), [])
        XCTAssertEqual(LocalLiveProtocol.deltaChunks("Hello."), ["Hello."])
        let long = String(repeating: "a", count: LocalLiveProtocol.maximumDeltaCharacters * 2 + 5)
        let chunks = LocalLiveProtocol.deltaChunks(long)
        XCTAssertEqual(chunks.map(\.count), [LocalLiveProtocol.maximumDeltaCharacters, LocalLiveProtocol.maximumDeltaCharacters, 5])
        XCTAssertEqual(chunks.joined(), long)

        // The plugin counts code points: a flag is two.
        let flags = String(repeating: "🇯🇵", count: LocalLiveProtocol.maximumDeltaCharacters)
        let flagChunks = LocalLiveProtocol.deltaChunks(flags)
        XCTAssertEqual(flagChunks.map(\.unicodeScalars.count), [LocalLiveProtocol.maximumDeltaCharacters, LocalLiveProtocol.maximumDeltaCharacters])
        XCTAssertEqual(flagChunks.joined(), flags)
    }

    private func makeLocalLiveSession() -> (LocalLiveSession, () -> [FakeGeminiLiveSocket]) {
        var sockets: [FakeGeminiLiveSocket] = []
        let session = LocalLiveSession(
            client: FakeLocalLiveConnection(),
            openSocket: { request in
                let socket = FakeGeminiLiveSocket(url: request.url!)
                sockets.append(socket)
                return socket
            },
            keepaliveInterval: .seconds(3_600),
            reconnectDelay: { _ in }
        )
        return (session, { sockets })
    }

    func testLocalLiveSessionAnswersThePluginsTurnsOnTheSameSocket() async throws {
        let (session, sockets) = makeLocalLiveSession()
        var turns: [String] = []
        session.onTurn = { id, text in turns.append("\(id):\(text)") }
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        XCTAssertEqual(socket.sent.first?["type"] as? String, "session.update")
        XCTAssertEqual(session.state, .connecting)

        socket.deliver(["type": "session.created"])
        socket.deliver(["type": "session.updated", "session": [String: Any]()])
        await localLiveSettle(until: { session.state == .ready })
        XCTAssertEqual(session.state, .ready)

        socket.deliver(["type": "conduit.turn", "turn_id": "t1", "text": "What's on today?"])
        await localLiveSettle(until: { !turns.isEmpty })
        XCTAssertEqual(turns, ["t1:What's on today?"])

        session.sendTurnDelta("t9", text: "not a turn of this call")
        session.sendTurnDelta("t1", text: "Two meetings.")
        session.sendTurnDone("t1")
        session.sendTurnDelta("t1", text: "too late")
        await localLiveSettle(until: { socket.sent.count >= 3 })
        let frames = socket.sent.dropFirst().map { "\($0["type"] as? String ?? ""):\($0["turn_id"] as? String ?? ""):\($0["text"] as? String ?? "")" }
        XCTAssertEqual(frames, ["conduit.turn.delta:t1:Two meetings.", "conduit.turn.done:t1:"])
        session.stop()
    }

    func testLocalLiveSessionSendsTypedTurnsForAnAnswerAndKeepsContextNotesBack() async throws {
        let (session, sockets) = makeLocalLiveSession()
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "session.updated"])
        await localLiveSettle(until: { session.state == .ready })

        var notesSent = 0
        session.send(.contextNote("typed in the chat"), onSent: { notesSent += 1 }, onFailure: nil)
        XCTAssertEqual(notesSent, 1, "Hermes has the chat: the note is settled without going out")
        session.send(.textTurn("Remind me at five"))
        await localLiveSettle(until: { socket.sent.count >= 3 })
        XCTAssertEqual(socket.sent.dropFirst().map { $0["type"] as? String }, ["conversation.item.create", "response.create"])
        session.stop()
    }

    func testLocalLiveSessionDropsOpenTurnsWhenItsConnectionEnds() async throws {
        let (session, sockets) = makeLocalLiveSession()
        var dropped = 0
        var replaced = 0
        session.onTurnsDropped = { dropped += 1 }
        session.onConnectionReplaced = { replaced += 1 }
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let first = try XCTUnwrap(sockets().first)
        first.deliver(["type": "session.updated"])
        first.deliver(["type": "conduit.turn", "turn_id": "t1", "text": "Hello"])
        await localLiveSettle(until: { session.state == .ready })

        first.serverClose(nil)
        await localLiveSettle(until: { sockets().count == 2 && sockets()[1].sent.isEmpty == false })
        XCTAssertEqual(dropped, 1)
        let second = try XCTUnwrap(sockets().last)
        second.deliver(["type": "session.updated"])
        await localLiveSettle(until: { replaced == 1 })
        XCTAssertEqual(replaced, 1)

        session.sendTurnDelta("t1", text: "for the old connection")
        await Task.yield()
        XCTAssertEqual(second.sent.count, 1, "a turn from the dropped connection can't be answered on the new one")
        session.stop()
    }

    func testLocalLiveSessionFailsWhenTheServerRefusesTheSetup() async throws {
        let (session, sockets) = makeLocalLiveSession()
        session.start()
        await localLiveSettle(until: { sockets().first?.sent.isEmpty == false })
        let socket = try XCTUnwrap(sockets().first)
        socket.deliver(["type": "error", "error": ["message": "Only 'realtime' session type is supported"]])
        await localLiveSettle(until: { if case .failed = session.state { return true }; return false })
        guard case .failed(let message) = session.state else { return XCTFail("\(session.state)") }
        XCTAssertTrue(message.contains("Only 'realtime' session type is supported"), message)
    }
}

// MARK: - Turns

@MainActor
private final class LocalLiveTurnScript {
    var busy = false
    var chat = LocalLiveTurnRunner.Chat(runtimeID: "rt-1")
    var submission: LocalLiveTurnRunner.Submission = .started(runtimeID: "rt-1")
    var redirectResult: VoiceRedirectResult = .redirected
    var busyReadFails = false
    /// Runs while a correction is on its way to Hermes.
    var duringRedirect: (() -> Void)?
    private(set) var submitted: [String] = []
    private(set) var redirected: [String] = []
    private(set) var spoken: [String] = []
    private(set) var done: [String] = []

    func makeRunner() -> LocalLiveTurnRunner {
        let runner = LocalLiveTurnRunner(backend: LocalLiveTurnRunner.Backend(
            resolveChat: { [unowned self] in self.chat },
            isBusy: { [unowned self] _ in
                if self.busyReadFails { throw URLError(.timedOut) }
                return self.busy
            },
            submit: { [unowned self] _, text in
                self.submitted.append(text)
                return self.submission
            },
            redirect: { [unowned self] _, text in
                self.redirected.append(text)
                self.duringRedirect?()
                return self.redirectResult
            }
        ))
        runner.onDelta = { [unowned self] id, text in self.spoken.append("\(id):\(text)") }
        runner.onDone = { [unowned self] id in self.done.append(id) }
        return runner
    }
}

@MainActor
extension VoiceConversationControllerTests {
    func testLocalLiveTurnStreamsHermesReplyAsItIsWritten() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "  What's on today?  ")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        XCTAssertEqual(script.submitted, ["What's on today?"])

        runner.observe(.messageDelta(sessionId: "other-chat", text: "not this call's"))
        runner.observe(.messageStart(sessionId: "rt-1"))
        runner.observe(.messageDelta(sessionId: "rt-1", text: "Two "))
        runner.observe(.messageDelta(sessionId: "rt-1", text: "meetings."))
        XCTAssertEqual(script.spoken, ["t1:Two ", "t1:meetings."])
        XCTAssertEqual(script.done, [])
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: "m1", content: "Two meetings.", reasoning: nil))
        XCTAssertEqual(script.spoken, ["t1:Two ", "t1:meetings."], "the reply isn't said twice")
        XCTAssertEqual(script.done, ["t1"])
        XCTAssertFalse(runner.isFollowingReply)
    }

    func testLocalLiveTurnSaysAWholeReplyThatCameWithoutDeltas() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Hi")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Hello there.", reasoning: nil))
        XCTAssertEqual(script.spoken, ["t1:Hello there."])
        XCTAssertEqual(script.done, ["t1"])
    }

    func testLocalLiveTurnWaitsForNoTypedTurnAndSaysTheChatIsBusy() async {
        let script = LocalLiveTurnScript()
        script.busy = true
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Hi")
        await localLiveSettle(until: { !script.done.isEmpty })
        XCTAssertEqual(script.submitted, [], "a turn already running in the chat is never steered")
        XCTAssertEqual(script.spoken, ["t1:\(LocalLiveTurnRunner.busyLine)"])
        XCTAssertEqual(script.done, ["t1"])

        // A chat whose state can't be read isn't sent to either.
        script.busy = false
        script.busyReadFails = true
        runner.start(turnID: "t2", text: "Hi")
        await localLiveSettle(until: { script.done.count == 2 })
        XCTAssertEqual(script.submitted, [])
        XCTAssertEqual(script.spoken.last, "t2:\(LocalLiveTurnRunner.failureLine)")
    }

    func testLocalLiveSaysWhatHermesDidWithWordsItDidNotStartATurnFor() async {
        let script = LocalLiveTurnScript()
        script.submission = .notStarted(message: "Queued in the chat.")
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Hi")
        await localLiveSettle(until: { !script.done.isEmpty })
        XCTAssertEqual(script.spoken, ["t1:Queued in the chat."])
        XCTAssertFalse(runner.isFollowingReply)
    }

    func testLocalLiveTurnSpokenOverHermesGoesIntoTheRunningReply() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Check my email")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        runner.observe(.messageDelta(sessionId: "rt-1", text: "Looking"))

        // The user speaks again: the plugin cancels t1 and sends t2.
        runner.cancel(turnID: "t1")
        // The talked-over reply's words still in flight aren't t2's answer.
        script.duringRedirect = { runner.observe(.messageDelta(sessionId: "rt-1", text: " through everything")) }
        runner.start(turnID: "t2", text: "only the work inbox")
        await localLiveSettle(until: { !script.redirected.isEmpty && !runner.isCorrecting })
        script.duringRedirect = nil
        XCTAssertEqual(script.spoken, ["t1:Looking"])
        XCTAssertEqual(script.redirected, ["only the work inbox"])
        XCTAssertEqual(script.submitted, ["Check my email"], "no second turn starts")

        // The marker for the cut-off words isn't the reply's end.
        runner.observe(.messageInterrupted(sessionId: "rt-1"))
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: nil, reasoning: nil))
        XCTAssertEqual(script.done, ["t2"], "an empty completion still ends the turn")

        script.redirectResult = .notRunning
        runner.start(turnID: "t3", text: "Thanks")
        await localLiveSettle(until: { script.submitted.count == 2 })
        XCTAssertEqual(script.redirected.count, 1, "nothing was running to redirect into")
        XCTAssertEqual(script.submitted.last, "Thanks")
    }

    func testLocalLiveTurnsRunOneAtATimeAndSkipOnesTheUserTalkedOver() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Check my email")
        await localLiveSettle(until: { !script.submitted.isEmpty })

        // Two turns back to back: the first was let go before it ran.
        runner.start(turnID: "t2", text: "only the work")
        runner.start(turnID: "t3", text: "only the work inbox")
        await localLiveSettle(until: { !script.redirected.isEmpty && !runner.isCorrecting })
        // t2 ran before t3 in the chain: it is settled too.
        XCTAssertEqual(script.redirected, ["only the work inbox"])
        XCTAssertEqual(script.submitted, ["Check my email"])
    }

    func testLocalLiveCancelledTurnStopsSpeakingButHermesKeepsWorking() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Plan my week")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        runner.cancel(turnID: "t1")
        runner.observe(.messageDelta(sessionId: "rt-1", text: "Monday…"))
        XCTAssertEqual(script.spoken, [])
        XCTAssertTrue(runner.isFollowingReply, "the reply still lands in the chat")
        runner.observe(.messageComplete(sessionId: "rt-1", messageId: nil, content: "Monday…", reasoning: nil))
        XCTAssertEqual(script.done, [], "the plugin already let the cancelled turn go")
        XCTAssertFalse(runner.isFollowingReply)
    }

    func testLocalLiveTurnSaysWhenHermesRanIntoAnError() async {
        let script = LocalLiveTurnScript()
        let runner = script.makeRunner()
        runner.start(turnID: "t1", text: "Delete the old files")
        await localLiveSettle(until: { !script.submitted.isEmpty })
        runner.observe(.messageError(sessionId: "other", message: "x"))
        XCTAssertEqual(script.done, [])
        runner.observe(.messageError(sessionId: "rt-1", message: "Provider timeout"))
        XCTAssertEqual(script.spoken, ["t1:\(LocalLiveTurnRunner.errorLine)"])
        XCTAssertEqual(script.done, ["t1"])
    }
}

// MARK: - Mode

@MainActor
extension AppStateVoiceCapabilityTests {
    func testLocalLiveIsOneLiveModeAndOpensItsOwnSheet() async {
        let suite = "LocalLiveAppState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = true
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: VoiceCapabilitySnapshot(isGatewayConnected: true, supportsTranscription: false, supportsSpeech: false, unavailableReason: "No STT"),
            isVoiceEnabled: false,
            transcriptionMode: .hermes,
            appleSpeechAvailability: .ready(localeIdentifier: "en-US")
        )
        XCTAssertFalse(appState.isLocalLiveEnabled, "Off by default")
        XCTAssertNil(appState.configuredLiveVoiceEngine(profile: appState.activeProfile))

        appState.setGrokLiveEnabled(true)
        appState.setLocalLiveEnabled(true)
        XCTAssertTrue(appState.isLocalLiveEnabled)
        XCTAssertFalse(appState.isGrokLiveEnabled, "turning Local Live on turns the others off")
        XCTAssertEqual(appState.configuredLiveVoiceEngine(profile: appState.activeProfile), .localLive)
        XCTAssertNil(appState.phoneVoiceUnavailableReason, "Local Live does not need Hermes speech providers")

        let opened = await appState.openVoiceConversation(
            PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: false, source: .composer)
        )
        XCTAssertTrue(opened)
        XCTAssertTrue(appState.showLocalLiveSheet)
        XCTAssertFalse(appState.showVoiceSheet)

        appState.setGeminiLiveEnabled(true)
        XCTAssertFalse(appState.isLocalLiveEnabled)
        XCTAssertFalse(appState.showLocalLiveSheet, "another live mode closes Local Live")
    }

    func testLocalLivePreferenceDecodesOffFromOlderBlobs() throws {
        let old = try JSONDecoder().decode(VoiceProfilePreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(old.localLiveEnabled)
        var preferences = VoiceProfilePreferences()
        preferences.localLiveEnabled = true
        let roundTrip = try JSONDecoder().decode(VoiceProfilePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(roundTrip.localLiveEnabled)
    }
}
