//
//  LocalLiveSession.swift
//  Conduit
//
//  One Local Live call through the Hermes host's relay to the user's speech
//  server. The first frame is the session.update; the call is ready once the
//  server confirms it. The server listens, decides when the user finished,
//  and speaks the answer; the answer itself comes from Hermes, as the
//  `conduit.turn` frames the plugin sends on this socket (`onTurn`), which
//  the call answers with `sendTurnDelta` and `sendTurnDone`.
//
//  It speaks the same seam as Gemini Live's session, so the shared
//  conversation controller (phases, transcript, the speaker echo guard,
//  hands-free end) drives Local Live unchanged.
//

import Foundation
import OSLog

private let localLiveLogger = Logger(subsystem: "com.milim.relay", category: "LocalLive")

@MainActor
final class LocalLiveSession: GeminiLiveSessionControlling {
    typealias State = GeminiLiveSession.State

    /// Retries after a connection attempt fails, for the first connect and
    /// every reconnect alike.
    static let maximumReconnectAttempts = 3

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onEvent: (@MainActor (GeminiLiveProtocol.ServerEvent) -> Void)?
    var onStateChange: (@MainActor (State) -> Void)?
    var onConnectionReplaced: (@MainActor () -> Void)?
    /// The speech server wants Hermes' reply to `text`.
    var onTurn: (@MainActor (_ turnID: String, _ text: String) -> Void)?
    /// The server moved on from a turn; its reply is no longer wanted.
    var onTurnCancel: (@MainActor (_ turnID: String) -> Void)?
    /// The connection the open turns came on ended: none of them can be
    /// answered any more.
    var onTurnsDropped: (@MainActor () -> Void)?
    private(set) var connectionGeneration = 0
    var stateDescription: String { "\(state)" }
    /// The server transcribes the user's speech once an utterance is done.
    var transcribesWholeUtterances: Bool { true }

    private let client: LocalLiveConnecting
    private let openSocket: @MainActor (URLRequest) -> GeminiLiveSocket
    private let setupTimeout: Duration
    private let keepaliveInterval: Duration
    private let reconnectDelay: @MainActor @Sendable (Int) async throws -> Void

    private var socket: GeminiLiveSocket?
    /// Identity of the current connection; frames from any other are ignored.
    private var connectionID = UUID()
    private var receiveTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var setupTimeoutTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var hasConnectedOnce = false
    /// The connection still waiting for session.updated, and which attempt
    /// it is: a socket that closes before then is a failed attempt.
    private var awaitingSetup: (id: UUID, attempt: Int)?
    private var lastSetupClose: GeminiLiveServerClose?
    /// Turns the plugin opened on the current connection: only those can
    /// be answered there.
    private var openTurns: Set<String> = []
    /// Whether the current response's transcript came as deltas; if not,
    /// its final transcript is shown instead.
    private var responseHadTranscript = false
    /// Frames go out one after another, in order.
    private var sendChain: Task<Void, Never>?

    init(
        client: LocalLiveConnecting,
        openSocket: @escaping @MainActor (URLRequest) -> GeminiLiveSocket = { URLSessionGeminiLiveSocket(request: $0) },
        setupTimeout: Duration = .seconds(15),
        keepaliveInterval: Duration = LocalLiveProtocol.keepaliveInterval,
        reconnectDelay: @escaping @MainActor @Sendable (Int) async throws -> Void = { attempt in
            try await Task.sleep(for: .seconds(min(8, 1 << attempt)))
        }
    ) {
        self.client = client
        self.openSocket = openSocket
        self.setupTimeout = setupTimeout
        self.keepaliveInterval = keepaliveInterval
        self.reconnectDelay = reconnectDelay
    }

    var isReady: Bool { state == .ready }

    func start() {
        guard state == .idle || state == .stopped || isFailed else { return }
        lastSetupClose = nil
        hasConnectedOnce = false
        state = .connecting
        connectTask = Task { [weak self] in await self?.connect(attempt: 0) }
    }

    func stop() {
        closeConnection()
        state = .stopped
    }

    func send(_ message: LiveVoiceClientMessage, onSent: (@MainActor () -> Void)?, onFailure: (@MainActor () -> Void)?) {
        switch message {
        case .contextNote, .toolResponse:
            // Hermes has the chat itself, and the call declares no tools:
            // the speech server's model is only a pipe to Hermes.
            onSent?()
            return
        case .audio, .audioStreamEnd, .textTurn:
            break
        }
        guard state == .ready, socket != nil else {
            onFailure?()
            return
        }
        let (frames, wantsResponse) = GrokLiveProtocol.frames(for: message)
        var texts = frames.compactMap { try? LocalLiveProtocol.encode($0) }
        guard texts.count == frames.count else {
            onFailure?()
            return
        }
        // A typed turn is answered like a spoken one: the server asks the
        // plugin, which sends it here as the call's next turn.
        if wantsResponse, let create = try? LocalLiveProtocol.encode(GrokLiveProtocol.responseCreate) {
            texts.append(create)
        }
        enqueue(texts, onSent: onSent, onFailure: onFailure)
    }

    // MARK: Turns

    /// Part of the reply to the plugin's turn `turnID`.
    func sendTurnDelta(_ turnID: String, text: String) {
        guard openTurns.contains(turnID) else { return }
        let frames = LocalLiveProtocol.deltaChunks(text).compactMap {
            try? LocalLiveProtocol.encode(LocalLiveProtocol.turnDelta(turnID: turnID, text: $0))
        }
        enqueue(frames, onSent: nil, onFailure: nil)
    }

    /// The reply to `turnID` is complete.
    func sendTurnDone(_ turnID: String) {
        guard openTurns.remove(turnID) != nil,
              let frame = try? LocalLiveProtocol.encode(LocalLiveProtocol.turnDone(turnID: turnID)) else { return }
        enqueue([frame], onSent: nil, onFailure: nil)
    }

    private func enqueue(_ texts: [String], onSent: (@MainActor () -> Void)?, onFailure: (@MainActor () -> Void)?) {
        guard !texts.isEmpty, let socket else {
            if texts.isEmpty { onSent?() } else { onFailure?() }
            return
        }
        let id = connectionID
        let previous = sendChain
        sendChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, id == self.connectionID else {
                onFailure?()
                return
            }
            do {
                for text in texts { try await socket.send(text) }
                onSent?()
            } catch {
                onFailure?()
                self.connectionFailed(id, error: error)
            }
        }
    }

    // MARK: Connection

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func fail(_ message: String) {
        closeConnection()
        state = .failed(message)
    }

    private func closeConnection() {
        connectTask?.cancel()
        connectTask = nil
        awaitingSetup = nil
        setupTimeoutTask?.cancel()
        setupTimeoutTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close()
        socket = nil
        connectionID = UUID()
        dropTurns()
    }

    private func dropTurns() {
        guard !openTurns.isEmpty else { return }
        openTurns = []
        onTurnsDropped?()
    }

    private func connect(attempt: Int) async {
        let request: URLRequest
        do {
            request = try await client.socketRequest()
        } catch {
            guard !Task.isCancelled, state != .stopped, !isFailed else { return }
            await retry(after: attempt, error: error)
            return
        }
        guard !Task.isCancelled, state != .stopped, !isFailed else { return }
        let socket = openSocket(request)
        do {
            try await socket.send(try LocalLiveProtocol.encode(LocalLiveProtocol.sessionUpdate))
        } catch {
            // A refused WebSocket upgrade surfaces here, on the first send.
            let close = await socket.serverClose(within: .milliseconds(400))
            socket.close()
            guard !Task.isCancelled, state != .stopped, !isFailed else { return }
            if let close, GrokLiveSession.isRefusal(close) {
                fail(Self.refusalMessage(close))
                return
            }
            if let close { lastSetupClose = close }
            await retry(after: attempt, error: error)
            return
        }
        guard !Task.isCancelled, state != .stopped, !isFailed else {
            socket.close()
            return
        }
        let id = UUID()
        receiveTask?.cancel()
        self.socket?.close()
        self.socket = socket
        connectionID = id
        awaitingSetup = (id, attempt)
        responseHadTranscript = false
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket, id: id) }
        // A server that neither confirms the session nor closes would leave
        // the call connecting forever.
        let timeout = setupTimeout
        setupTimeoutTask?.cancel()
        setupTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.awaitingSetup?.id == id else { return }
            localLiveLogger.error("Local Live session setup timed out")
            self.connectionFailed(id, error: URLError(.timedOut))
        }
        startKeepalive(on: id)
    }

    private func startKeepalive(on id: UUID) {
        keepaliveTask?.cancel()
        let interval = keepaliveInterval
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, id == self.connectionID,
                      let ping = try? LocalLiveProtocol.encode(LocalLiveProtocol.keepalive) else { return }
                self.enqueue([ping], onSent: nil, onFailure: nil)
            }
        }
    }

    private func receiveLoop(_ socket: GeminiLiveSocket, id: UUID) async {
        while !Task.isCancelled {
            let data: Data
            do {
                data = try await socket.receive()
            } catch {
                let beforeSetup = awaitingSetup?.id == id
                let close = await socket.serverClose(within: beforeSetup ? .milliseconds(400) : .milliseconds(100))
                connectionFailed(id, error: error, serverClose: close)
                return
            }
            guard id == connectionID else { return }
            if let turn = LocalLiveProtocol.turnFrame(data) {
                handle(turn)
                continue
            }
            for frame in GrokLiveProtocol.decode(data) {
                // A frame can end this connection.
                guard id == connectionID else { return }
                handle(frame, connection: id)
            }
        }
    }

    private func handle(_ frame: LocalLiveProtocol.TurnFrame) {
        switch frame {
        case .turn(let turnID, let text):
            openTurns.insert(turnID)
            onTurn?(turnID, text)
        case .cancel(let turnID):
            guard openTurns.remove(turnID) != nil else { return }
            onTurnCancel?(turnID)
        }
    }

    private func handle(_ frame: GrokLiveProtocol.ServerFrame, connection id: UUID) {
        switch frame {
        case .sessionUpdated:
            guard awaitingSetup?.id == id else { return }
            awaitingSetup = nil
            setupTimeoutTask?.cancel()
            setupTimeoutTask = nil
            lastSetupClose = nil
            let replaced = hasConnectedOnce
            hasConnectedOnce = true
            if replaced {
                connectionGeneration += 1
                onConnectionReplaced?()
            }
            state = .ready
        case .error(let message):
            // Before the session is set up, the server refused it: a retry
            // would send the same.
            if awaitingSetup?.id == id {
                localLiveLogger.error("The speech server refused the session setup")
                fail(message.isEmpty
                    ? AppLocalization.string("Your speech server refused the call.")
                    : AppLocalization.string("Your speech server refused the call: \(GrokLiveSession.clipped(message))"))
                return
            }
            // A refused response.create or similar: the call goes on.
            localLiveLogger.notice("Local Live error event: \(message, privacy: .private)")
        case .responseStarted:
            responseHadTranscript = false
        case .responseDone, .acceptedFunctions:
            break
        case .outputTranscriptDone(let text):
            if !responseHadTranscript { onEvent?(.outputTranscription(text)) }
        case .inputTranscriptSnapshot(_, let text):
            // The server sends each utterance's transcript once, when it is done.
            onEvent?(.inputTranscription(text))
        case .event(let event):
            if case .outputTranscription = event { responseHadTranscript = true }
            onEvent?(event)
        }
    }

    private func connectionFailed(_ id: UUID, error: Error, serverClose: GeminiLiveServerClose? = nil) {
        guard id == connectionID, state != .stopped, !isFailed else { return }
        // Never the error's description: it can carry the connection URL,
        // whose ticket is a credential.
        let nsError = error as NSError
        localLiveLogger.error("Local Live connection lost: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) closeCode=\(serverClose?.code ?? 0, privacy: .public)")
        let pendingSetup = awaitingSetup?.id == id ? awaitingSetup : nil
        socket?.close()
        socket = nil
        receiveTask?.cancel()
        receiveTask = nil
        awaitingSetup = nil
        setupTimeoutTask?.cancel()
        setupTimeoutTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        connectionID = UUID()
        dropTurns()
        if let serverClose, GrokLiveSession.isRefusal(serverClose) {
            fail(Self.refusalMessage(serverClose))
            return
        }
        connectTask?.cancel()
        guard let pendingSetup else {
            // A running call dropped: connect again.
            state = .reconnecting
            connectTask = Task { [weak self] in await self?.connect(attempt: 0) }
            return
        }
        if let serverClose { lastSetupClose = serverClose }
        connectTask = Task { [weak self] in await self?.retry(after: pendingSetup.attempt, error: error) }
    }

    private func retry(after attempt: Int, error: Error) async {
        guard attempt < Self.maximumReconnectAttempts else {
            if let close = lastSetupClose {
                fail(AppLocalization.string("Couldn't connect to your speech server: \(close.summary)"))
            } else if let reason = (error as? LocalizedError)?.errorDescription, !(error is URLError) {
                // The dashboard's own reason (signed out, no ticket…).
                fail(reason)
            } else {
                fail(AppLocalization.string("Couldn't connect to your speech server."))
            }
            return
        }
        if state != .connecting { state = .reconnecting }
        do {
            try await reconnectDelay(attempt)
        } catch {
            return
        }
        guard !Task.isCancelled, state != .stopped, !isFailed else { return }
        await connect(attempt: attempt + 1)
    }

    nonisolated static func refusalMessage(_ close: GeminiLiveServerClose) -> String {
        if close.isHTTPStatus, close.code == 404 {
            return LocalLiveProtocol.pluginMissingReason
        }
        return AppLocalization.string("Your speech server refused the call: \(close.summary)")
    }
}
