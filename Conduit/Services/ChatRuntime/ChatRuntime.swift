#if LAA_BUILD
import Foundation

/// In-process Chat contract v1. Identifiers at this boundary are durable
/// conversation keys and client turn UUIDs, not Hermes runtime or writer ids.
@MainActor protocol ChatRuntime: AnyObject {
    func capabilities(conversationID: String?) async throws -> ChatCapabilities
    func create(_ request: ChatCreateRequest) async throws -> ChatConversationState
    func open(conversationID: String, sinceSeq: UInt64?) async throws -> ChatConversationState
    func list(profile: String, limit: Int, cursor: String?, includeArchived: Bool) async throws -> ChatConversationPage
    func update(conversationID: String, title: String?, archived: Bool?, pinned: Bool?) async throws
    func submit(_ request: ChatSubmitRequest) async throws -> ChatAcceptance
    func steer(conversationID: String, text: String) async throws -> ChatControlStatus
    func interrupt(conversationID: String) async throws -> ChatControlStatus
    func respond(conversationID: String, requestID: String, answer: ChatRequestAnswer) async throws
    func set(conversationID: String, model: String?, provider: String?, effort: String?, confirmed: Bool) async throws -> ChatSettingsResult
    func context(conversationID: String) async throws -> ChatContext
    func compact(conversationID: String, focus: String?) async -> ContextCompactResult
    func addAttachment(conversationID: String, kind: ChatAttachment.Kind, name: String, data: Data) async throws -> String
    func events(conversationID: String, sinceSeq: UInt64?) -> AsyncStream<ChatRuntimeEvent>
}

struct ChatCapabilities {
    let contract = 1
    let text: Bool
    let thought: Bool?
    let image: Bool
    let file: Bool
    let compaction: Bool
    let steering: Bool
    let model: String?
    let provider: String?
    /// The shared picker catalogue also carries labels and capabilities.
    let models: [ProviderInfo]
}

struct ChatCreateRequest {
    let profile: String
    var model: String? = nil
    var effort: String? = nil
    var cwd: String? = nil
    var hidden: Bool? = nil
    var title: String? = nil
    var branchOf: String? = nil
}

struct ChatConversationState {
    let conversationID: String
    let running: Bool
    let turnID: UUID?
    let messages: [ChatMessage]
    let openRequests: [ChatOpenRequest]
    let context: ChatContext
    var missedEvents: [ChatRuntimeEvent] = []
}

struct ChatConversationRow {
    let conversationID: String
    let title: String
    let model: String
    let archived: Bool
    let pinned: Bool?
}

struct ChatConversationPage {
    let rows: [ChatConversationRow]
    let nextCursor: String?
}

struct ChatOpenRequest: Equatable {
    enum Kind: String { case approval, clarify, secret }
    let id: String
    let kind: Kind
}

enum ChatRequestAnswer {
    case approval(String)
    case clarify(String, questionID: String?)
    case secret(String)
}

struct ChatAttachment {
    enum Kind { case image, file }
    let kind: Kind
    let name: String
    let data: Data
}

struct ChatSubmitRequest {
    enum Mode { case normal, queued, hidden }
    let conversationID: String
    let turnID: UUID
    let text: String
    var attachments: [ChatAttachment] = []
    var mode: Mode = .normal
    var surface: String? = nil
    var voiceTurn = false
}

enum ChatAcceptance: String { case started, queued, steered }
enum ChatControlStatus: String { case accepted, interrupted }

struct ChatSettingsResult {
    let applied: Bool
    let confirmRequired: Bool
    let model: String?
    var deferred = false
    var confirmation: String? = nil
}

struct ChatContext: Equatable {
    struct Category: Equatable { let id: String; let label: String; let tokens: Int }
    var used: Int? = nil
    var window: Int? = nil
    var fixed: Int? = nil
    var recent: Int? = nil
    var categories: [Category] = []
}

struct ContextCompactResult: Equatable {
    enum Status: String { case compacted, nothingToCompact = "nothing_to_compact", inProgress = "in_progress", failed }
    let status: Status
    var beforeTokens: Int? = nil
    var afterTokens: Int? = nil
    var fixedTokens: Int? = nil
    var recentTokens: Int? = nil
    var failure: ChatRuntimeFailure? = nil

    var message: String? { LAAChatRuntimeCopy.compactionNotice(self) }
}

struct ChatRuntimeFailure: Error, LocalizedError, Equatable, Sendable {
    enum Code: String, Sendable {
        case quotaExhausted = "quota_exhausted", modelUnavailable = "model_unavailable", interrupted, timeout
        case contextOverflow = "context_overflow", toolFailed = "tool_failed", runtimeUnavailable = "runtime_unavailable"
        case rejected, `internal`
    }
    let code: Code
    let retryAt: Date?

    init(_ code: Code, retryAt: Date? = nil) { self.code = code; self.retryAt = retryAt }

    var errorDescription: String? { LAAChatRuntimeCopy.failureNotice(self) }
}

struct ChatEventStamp: Equatable {
    let conversationID: String
    let turnID: UUID
    let seq: UInt64
    let at: Date
}

enum ChatRuntimeEvent {
    case started(ChatEventStamp, model: String?, provider: String?, effort: String?)
    case thoughtDelta(ChatEventStamp, text: String)
    case textDelta(ChatEventStamp, text: String)
    case textInterim(ChatEventStamp, text: String)
    case toolStarted(ChatEventStamp, callID: String, name: String, summary: String?)
    case toolFinished(ChatEventStamp, callID: String, ok: Bool?, summary: String?, card: String?)
    case requestOpened(ChatEventStamp, ChatOpenRequest)
    case requestClosed(ChatEventStamp, requestID: String)
    case contextUpdated(ChatEventStamp, used: Int?, window: Int?)
    case compactionProgress(ChatEventStamp, started: Bool)
    case completed(ChatEventStamp, text: String?, messageID: String?, metrics: TurnMetrics)
    case failed(ChatEventStamp, ChatRuntimeFailure, metrics: TurnMetrics)

    var stamp: ChatEventStamp {
        switch self {
        case .started(let stamp, _, _, _), .thoughtDelta(let stamp, _), .textDelta(let stamp, _),
             .textInterim(let stamp, _), .toolStarted(let stamp, _, _, _), .toolFinished(let stamp, _, _, _, _),
             .requestOpened(let stamp, _), .requestClosed(let stamp, _), .contextUpdated(let stamp, _, _),
             .compactionProgress(let stamp, _), .completed(let stamp, _, _, _), .failed(let stamp, _, _): return stamp
        }
    }
}
#endif
