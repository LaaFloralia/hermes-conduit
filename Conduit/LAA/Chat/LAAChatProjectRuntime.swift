#if LAA_BUILD
import Foundation
import OSLog

struct LAAChatProjectFailure: Error, Equatable, Sendable {
    enum Code: String, Sendable {
        case quotaExhausted = "quota_exhausted", modelUnavailable = "model_unavailable"
        case runtimeUnavailable = "runtime_unavailable", rejected, interrupted, timeout
        case contextOverflow = "context_overflow", toolFailed = "tool_failed", internalError = "internal"
        case unknownDelivery, localStorage
    }
    let code: Code
    let retryAt: Date?
    init(_ code: Code, retryAt: Date? = nil) { self.code = code; self.retryAt = retryAt }
}

struct LAAChatProjectRoute: Equatable, Sendable {
    let model: String
    let provider: String
    let effort: String

    init(model: String, provider: String, effort: String) {
        self.model = model; self.provider = provider; self.effort = effort
    }
    init(_ model: LAAChatProject.Model) throws {
        guard let provider = model.provider else { throw LAAChatProjectFailure(.modelUnavailable) }
        self.init(model: model.rawValue, provider: provider, effort: model.effort)
    }
}

/// Small ChatRuntime-shaped edge; the transport-specific mapping is in the
/// Hermes adapter, not in the store, prompt builder, or list/detail views.
@MainActor protocol LAAChatProjectRuntime {
    func create(_ request: LAAChatProjectCreate) async throws
    func submit(_ request: LAAChatProjectSubmit) -> AsyncThrowingStream<LAAChatProjectEvent, Error>
    func replay(conversationID: UUID, turnID: UUID) async throws -> [LAAChatProjectEvent]
}

struct LAAChatProjectCreate: Equatable, Sendable {
    static let profile = "laa-chat-projects"
    let conversationID: UUID
    let route: LAAChatProjectRoute
    let title: String
    let hidden = true
}

struct LAAChatProjectSubmit: Equatable, Sendable {
    let conversationID: UUID
    let turnID: UUID
    let route: LAAChatProjectRoute
    let system: String
    let history: [LAAChatProject.Message]
    let text: String
}

enum LAAChatProjectEvent: Equatable, Sendable {
    case accepted
    case started(LAAChatProjectRoute)
    case text(String)
    case completed(String)
    case failed(LAAChatProjectFailure)
}

enum LAAChatProjectPrompt {
    static let contextLimit = 24_000

    static func assemble(project: LAAChatProject, route: LAAChatProjectRoute, question: LAAChatProject.Message,
                         verifiedAnswer: String?) throws -> LAAChatProjectSubmit {
        let system = if let verifiedAnswer {
            project.context + "\n\n" + LAACopy.ChatProjects.pokemonRender(verifiedAnswer)
        } else {
            project.context
        }
        let required = system.utf8.count + question.text.utf8.count
        guard required < contextLimit else { throw LAAChatProjectFailure(.contextOverflow) }
        // Keep recent *complete pairs* within the provider's quick-chat
        // budget. All messages remain available in the local transcript.
        var remaining = contextLimit - required
        var history: [LAAChatProject.Message] = []
        var end = project.history.endIndex
        while end >= 2 {
            let pair = project.history[(end - 2)..<end]
            let bytes = pair.reduce(0) { $0 + $1.text.utf8.count }
            guard bytes < remaining else { break }
            history.insert(contentsOf: pair, at: 0)
            remaining -= bytes
            end -= 2
        }
        return .init(conversationID: project.id, turnID: question.id, route: route, system: system, history: history, text: question.text)
    }
}

@MainActor enum LAAChatProjectRunner {
    private static let log = Logger(subsystem: "com.laa.conduit", category: "ChatProjectTurns")

    /// Runtime output is accepted only after it has identified the exact pin.
    /// Pokémon facts are deterministic; a model edit cannot change them, or
    /// add a guarantee that the evidence doesn't support.
    static func run(runtime: any LAAChatProjectRuntime, project: LAAChatProject, question: LAAChatProject.Message,
                    verifiedAnswer: String? = nil, onVisibleText: (String) -> Void = { _ in }) async throws -> String {
        let began = ContinuousClock.now
        var accepted: Duration?, firstEvent: Duration?, firstText: Duration?, firstVisible: Duration?
        var status = "failed"
        defer {
            func milliseconds(_ value: Duration?) -> Int64 {
                guard let parts = value?.components else { return -1 }
                return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
            }
            log.info("project_turn model=\(project.model.rawValue, privacy: .public) outcome=\(status, privacy: .public) accepted_ms=\(milliseconds(accepted)) first_event_ms=\(milliseconds(firstEvent)) first_text_ms=\(milliseconds(firstText)) first_visible_update_ms=\(milliseconds(firstVisible)) total_ms=\(milliseconds(began.duration(to: .now)))")
        }
        let route = try LAAChatProjectRoute(project.model)
        let submit = try LAAChatProjectPrompt.assemble(project: project, route: route, question: question, verifiedAnswer: verifiedAnswer)
        try await runtime.create(.init(conversationID: project.id, route: route, title: project.name))
        var sawStart = false
        var output = ""
        for try await event in runtime.submit(submit) {
            let elapsed = began.duration(to: .now)
            if event != .accepted, firstEvent == nil {
                firstEvent = elapsed
                // A fast terminal socket event can beat its RPC response.
                if accepted == nil { accepted = elapsed }
            }
            switch event {
            case .accepted: if accepted == nil { accepted = elapsed }
            case .started(let effective):
                guard effective == route else { throw LAAChatProjectFailure(.modelUnavailable) }
                sawStart = true
            case .text(let delta):
                guard sawStart else { throw LAAChatProjectFailure(.unknownDelivery) }
                guard !delta.isEmpty else { continue }
                if firstText == nil { firstText = elapsed }
                output += delta
                if verifiedAnswer == nil || verifiedAnswer?.hasPrefix(output) == true {
                    if firstVisible == nil, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { firstVisible = elapsed }
                    onVisibleText(output)
                }
            case .completed(let final):
                guard sawStart else { throw LAAChatProjectFailure(.unknownDelivery) }
                let answer = verifiedAnswer ?? (final.isEmpty ? output : final)
                guard !answer.isEmpty else { throw LAAChatProjectFailure(.internalError) }
                if firstVisible == nil { firstVisible = elapsed; onVisibleText(answer) }
                status = "completed"
                return answer
            case .failed(let error): throw error
            }
        }
        throw LAAChatProjectFailure(.unknownDelivery)
    }
}

#if DEBUG
/// In-memory, no network, pins still validated by the same runner as release.
@MainActor struct LAAChatProjectFixtureRuntime: LAAChatProjectRuntime {
    func create(_ request: LAAChatProjectCreate) async throws {}
    func replay(conversationID: UUID, turnID: UUID) async throws -> [LAAChatProjectEvent] { [] }
    func submit(_ request: LAAChatProjectSubmit) -> AsyncThrowingStream<LAAChatProjectEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.accepted)
            continuation.yield(.started(request.route))
            continuation.yield(.text("試験用の返答です。"))
            continuation.yield(.completed("試験用の返答です。"))
            continuation.finish()
        }
    }
}
#endif
#endif
