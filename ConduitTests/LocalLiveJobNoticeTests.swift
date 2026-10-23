//
//  LocalLiveJobNoticeTests.swift
//  ConduitTests
//
//  A Local Live call that runs its own agent (Live > Local) has the fast
//  model on the front: a background job's result is news to it and must be
//  said, once, as the call's own turn. A Local Live call that hands each
//  utterance to Hermes (hermes_turns) still drops it: Hermes' reply is the
//  call's own turn and a notice said as well would be said twice.
//

import AVFAudio
import XCTest
@testable import Conduit

@MainActor
final class LocalLiveJobNoticeTests: XCTestCase {
    private func settle(until done: () -> Bool, limit: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !done(), ContinuousClock.now < deadline { await Task.yield() }
    }

    private func makeSupervisor() -> VoiceBackgroundJobSupervisor {
        VoiceBackgroundJobSupervisor(backend: FakeVoiceJobBackend().backend, pollInterval: .seconds(3_600))
    }

    /// A Local Live call on the real session seam, driven by a fake socket.
    private func makeLocalLiveController(
        agent: Bool,
        supervisor: VoiceBackgroundJobSupervisor,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> (controller: GeminiLiveConversationController, session: LocalLiveSession,
          input: FakeGeminiLiveInput, sockets: () -> [FakeGeminiLiveSocket]) {
        var sockets: [FakeGeminiLiveSocket] = []
        let session = LocalLiveSession(
            client: FakeLocalLiveConnection(),
            openSocket: { request in
                let socket = FakeGeminiLiveSocket(url: request.url!)
                sockets.append(socket)
                return socket
            },
            setupTimeout: .seconds(10),
            readinessTimeout: .seconds(60),
            keepaliveInterval: .seconds(3_600),
            reconnectDelay: { _ in }
        )
        if agent {
            session.agentSetup = { .init(instructions: "Be brief.", functions: []) }
        }
        let input = FakeGeminiLiveInput()
        let controller = GeminiLiveConversationController(
            makeSession: { session },
            availability: { .available(model: "qwen3.8-omni-flash-realtime") },
            tools: GeminiLiveToolBridge(supervisor: supervisor, webSearch: nil, holdsJobCalls: false),
            input: input,
            output: FakeGeminiLiveOutput(),
            now: Date.init,
            headsetMute: HeadsetMicrophoneMute(system: FakeSystemInputMute()),
            notificationCenter: notificationCenter
        )
        return (controller, session, input, { sockets })
    }

    /// The frame types the call has sent so far.
    private func frameTypes(_ socket: FakeGeminiLiveSocket) -> [String] {
        socket.sent.map { $0["type"] as? String ?? "" }
    }

    /// The server's setup and readiness check, as the app drives them.
    private func makeReady(_ session: LocalLiveSession, _ socket: FakeGeminiLiveSocket) async throws {
        socket.deliver(["type": "session.updated"])
        await settle(until: { frameTypes(socket).contains("response.create") })
        let check = try XCTUnwrap(socket.sent.last { $0["type"] as? String == "response.create" })
        let response = try XCTUnwrap(check["response"] as? [String: Any])
        let item = try XCTUnwrap((response["input"] as? [[String: Any]])?.first)
        let content = try XCTUnwrap((item["content"] as? [[String: Any]])?.first)
        let marker = try XCTUnwrap(content["text"] as? String)
        socket.deliver(["type": "conduit.turn", "turn_id": "ready", "text": marker])
        await settle(until: { session.state == .ready })
    }

    /// The call's own turns that carry `text`.
    private func turns(_ socket: FakeGeminiLiveSocket, containing text: String) -> [String] {
        socket.sent.compactMap { frame in
            guard frame["type"] as? String == "conversation.item.create",
                  let item = frame["item"] as? [String: Any],
                  let content = (item["content"] as? [[String: Any]])?.first,
                  let said = content["text"] as? String,
                  said.contains(text) else { return nil }
            return said
        }
    }

    private func finishAJob(_ supervisor: VoiceBackgroundJobSupervisor) async {
        _ = await supervisor.startJob(instructions: "check the mail")
        supervisor.observe(.messageComplete(sessionId: "st-1", messageId: nil, content: "3 unread.", reasoning: nil))
    }

    // MARK: Routing

    func testAnAgentLocalLiveCallDeliversJobNewsAndAHermesTurnCallStillDropsIt() {
        XCTAssertEqual(LocalLiveNoticeHandling.forCall(runsAgentTurns: true), .deliverAsUpdate)
        XCTAssertEqual(LocalLiveNoticeHandling.forCall(runsAgentTurns: false), .drop)
    }

    func testALocalLiveSessionSaysWhetherItsConnectionRunsAgentTurns() async throws {
        let agent = makeLocalLiveController(agent: true, supervisor: makeSupervisor())
        await agent.controller.start()
        await settle(until: { agent.sockets().isEmpty == false })
        let agentSocket = try XCTUnwrap(agent.sockets().first)
        try await makeReady(agent.session, agentSocket)
        XCTAssertTrue(agent.session.runsAgentTurns)
        XCTAssertTrue(agent.controller.sessionRunsAgentTurns)
        agent.controller.stop()

        let plain = makeLocalLiveController(agent: false, supervisor: makeSupervisor())
        await plain.controller.start()
        await settle(until: { plain.sockets().isEmpty == false })
        let plainSocket = try XCTUnwrap(plain.sockets().first)
        try await makeReady(plain.session, plainSocket)
        XCTAssertFalse(plain.session.runsAgentTurns)
        XCTAssertFalse(plain.controller.sessionRunsAgentTurns)
        plain.controller.stop()
    }

    // MARK: Delivery

    func testALocalLiveAgentCallSaysAFinishedJobsResultOnce() async throws {
        let supervisor = makeSupervisor()
        let call = makeLocalLiveController(agent: true, supervisor: supervisor)
        await call.controller.start()
        await settle(until: { call.sockets().isEmpty == false })
        let socket = try XCTUnwrap(call.sockets().first)
        try await makeReady(call.session, socket)
        await finishAJob(supervisor)

        call.controller.deliverPendingJobUpdates()
        await settle(until: { supervisor.jobs.first?.outcomeDelivered == true })
        XCTAssertEqual(turns(socket, containing: "3 unread.").count, 1, "the result is said once, on this call")
        XCTAssertTrue(supervisor.jobs.first?.outcomeDelivered == true, "settled only once the socket took it")

        call.controller.deliverPendingJobUpdates()
        call.controller.flushPendingTextIfIdle()
        await settle(until: { false }, limit: .milliseconds(150))
        XCTAssertEqual(turns(socket, containing: "3 unread.").count, 1, "never said twice")
        call.controller.stop()
    }

    func testALocalLiveAgentCallKeepsTheResultUntilItsConnectionIsReady() async throws {
        let supervisor = makeSupervisor()
        let call = makeLocalLiveController(agent: true, supervisor: supervisor)
        await call.controller.start()
        await settle(until: { call.sockets().isEmpty == false })
        let socket = try XCTUnwrap(call.sockets().first)
        await finishAJob(supervisor)

        // Still connecting: nothing can be sent, so nothing is spent.
        XCTAssertFalse(call.session.isReady)
        call.controller.deliverPendingJobUpdates()
        XCTAssertTrue(turns(socket, containing: "3 unread.").isEmpty)
        XCTAssertFalse(supervisor.jobs.first?.outcomeDelivered == true)

        // Ready: the result goes out then, once.
        try await makeReady(call.session, socket)
        call.controller.deliverPendingJobUpdates()
        await settle(until: { supervisor.jobs.first?.outcomeDelivered == true })
        XCTAssertEqual(turns(socket, containing: "3 unread.").count, 1)
        call.controller.stop()
    }

    func testALocalLiveAgentCallHoldsTheResultWhileTheAudioIsPaused() async throws {
        struct AlarmRinging: Error {}
        let center = NotificationCenter()
        let supervisor = makeSupervisor()
        let call = makeLocalLiveController(agent: true, supervisor: supervisor, notificationCenter: center)
        await call.controller.start()
        await settle(until: { call.sockets().isEmpty == false })
        let socket = try XCTUnwrap(call.sockets().first)
        try await makeReady(call.session, socket)

        call.input.startError = AlarmRinging()
        call.input.stop()
        call.input.onInterrupted?()
        XCTAssertTrue(call.controller.isAudioPausedForTesting)

        await finishAJob(supervisor)
        call.controller.deliverPendingJobUpdates()
        XCTAssertTrue(turns(socket, containing: "3 unread.").isEmpty, "nothing is said over the alarm")
        XCTAssertFalse(supervisor.jobs.first?.outcomeDelivered == true, "still pending, not spent")

        call.input.startError = nil
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSessionInterruptionType.ended.rawValue]
        )
        await settle(until: { !call.controller.isAudioPausedForTesting })
        call.controller.deliverPendingJobUpdates()
        await settle(until: { supervisor.jobs.first?.outcomeDelivered == true })
        XCTAssertEqual(turns(socket, containing: "3 unread.").count, 1)
        call.controller.stop()
    }

    func testALocalLiveHermesTurnCallDropsTheNoticeWithoutSayingIt() async throws {
        let supervisor = makeSupervisor()
        let call = makeLocalLiveController(agent: false, supervisor: supervisor)
        await call.controller.start()
        await settle(until: { call.sockets().isEmpty == false })
        let socket = try XCTUnwrap(call.sockets().first)
        try await makeReady(call.session, socket)
        await finishAJob(supervisor)

        // What the notice route does for this call, unchanged: dropped rather
        // than said a second time after Hermes' own reply.
        XCTAssertEqual(LocalLiveNoticeHandling.forCall(runsAgentTurns: call.session.runsAgentTurns), .drop)
        supervisor.dropPendingNotices()
        await settle(until: { false }, limit: .milliseconds(150))
        XCTAssertTrue(turns(socket, containing: "3 unread.").isEmpty)
        XCTAssertNil(supervisor.takePendingNotice(), "dropped, not left for another call")
        call.controller.stop()
    }
}
