#if LAA_BUILD
import Foundation

/// Hermes dashboard adapter. The runtime handle, all alias bookkeeping and
/// the wire names stay here; a profile's REST authentication is supplied by
/// the existing dashboard bridge (no additional hop in interactive Chat).
@MainActor final class HermesChatRuntime: ChatRuntime {
    typealias SubmitWire = @MainActor (String, ChatSubmitRequest) async throws -> PromptSubmissionOutcome
    private struct Binding {
        let runtimeID: String
        let identity: HermesChatTimeline.Identity
    }
    private struct Submission {
        let conversationID: String
        let task: Task<PromptSubmissionOutcome, Error>
    }

    private weak var client: HermesClient?
    private let timeline: HermesChatTimeline
    private let sendWire: SubmitWire
    private var bindings: [String: Binding] = [:]
    private var byRuntime: [String: String] = [:]
    private var lastWireSequence: [String: Int] = [:]
    private var submissions: [UUID: Submission] = [:]
    var http: (@MainActor (String) async throws -> [String: Any])?
    var mutate: (@MainActor (String, String, [String: Any]) async throws -> Void)?

    convenience init(client: HermesClient) {
        self.init(timeline: .init()) { [weak client] runtimeID, request in
            guard let client else { throw ChatRuntimeFailure(.runtimeUnavailable) }
            return try await client.sendPrompt(runtimeID, text: request.text, surface: request.surface,
                                               voiceTurn: request.voiceTurn, queued: request.mode == .queued,
                                               hidden: request.mode == .hidden, clientTurnID: request.turnID)
        }
        self.client = client
    }

    init(timeline: HermesChatTimeline, submitWire: @escaping SubmitWire) {
        self.timeline = timeline
        self.sendWire = submitWire
    }

    func bind(conversationID: String, runtimeID: String, identity: HermesChatTimeline.Identity) {
        guard !conversationID.isEmpty, !runtimeID.isEmpty else { return }
        if let previous = bindings[conversationID]?.runtimeID, previous != runtimeID {
            byRuntime[previous] = nil
            lastWireSequence[previous] = nil
        }
        if let previousOwner = byRuntime[runtimeID], previousOwner != conversationID {
            bindings[previousOwner] = nil
            lastWireSequence[runtimeID] = nil
        }
        bindings[conversationID] = Binding(runtimeID: runtimeID, identity: identity)
        byRuntime[runtimeID] = conversationID
    }

    func observeWire(_ params: AnyCodable, parsed: StreamEvent?) {
        guard let fields = params.objectValue, let runtimeID = fields["session_id"]?.stringValue,
              let id = byRuntime[runtimeID] else { return }
        if let seq = fields["seq"]?.intValue, seq >= 0 {
            if let last = lastWireSequence[runtimeID], seq <= last { return }
            lastWireSequence[runtimeID] = seq
        }
        if let turnID = timeline.observe(id, wire: fields, parsed: parsed) {
            // A completion for an offscreen view has no render settlement.
            // Give the existing render drain (≤1.2s) and RPC ack a chance.
            let timeline = self.timeline
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                timeline.flushTerminal(id, turnID: turnID)
            }
        }
    }

    func requestOpened(runtimeID: String, requestID: String, kind: ChatOpenRequest.Kind) {
        observeWire(.object(["type": .string("request.open"), "session_id": .string(runtimeID),
                             "payload": .object(["id": .string(requestID), "kind": .string(kind.rawValue)])]), parsed: nil)
    }

    func requestClosed(runtimeID: String, requestID: String) {
        observeWire(.object(["type": .string("request.cancel"), "session_id": .string(runtimeID),
                             "payload": .object(["id": .string(requestID)])]), parsed: nil)
    }

    func visible(runtimeID: String?) {
        if let runtimeID, let id = byRuntime[runtimeID] { timeline.visible(id) }
    }

    func settled(runtimeID: String?) {
        if let runtimeID, let id = byRuntime[runtimeID] { timeline.settled(id) }
    }

    func events(conversationID: String, sinceSeq: UInt64?) -> AsyncStream<ChatRuntimeEvent> {
        timeline.events(conversationID, sinceSeq: sinceSeq)
    }

    private func host() throws -> HermesClient {
        guard let client else { throw ChatRuntimeFailure(.runtimeUnavailable) }
        return client
    }

    private func binding(_ id: String) throws -> Binding {
        guard let binding = bindings[id] else { throw ChatRuntimeFailure(.runtimeUnavailable) }
        return binding
    }

    private func typed<T>(_ block: () async throws -> T) async throws -> T {
        do { return try await block() } catch { throw HermesChatFailure.failure(error) }
    }

    func capabilities(conversationID: String?) async throws -> ChatCapabilities {
        try await typed {
            let result = try await host().modelOptions(sessionId: conversationID.map { try binding($0).runtimeID })
            // This reports adapter support, not whether the selected model
            // will emit thought or accept an image on its next turn.
            return .init(text: true, thought: true, image: true, file: true, compaction: true, steering: true,
                         model: result.model, provider: result.provider, models: result.providers ?? [])
        }
    }

    func create(_ request: ChatCreateRequest) async throws -> ChatConversationState {
        try await typed {
            var fields: [String: Any] = ["profile": request.profile, "cols": 96, "source": "desktop"]
            fields["model"] = request.model
            fields["reasoning_effort"] = request.effort
            fields["cwd"] = request.cwd
            fields["title"] = request.title
            if let hidden = request.hidden {
                fields["hidden"] = hidden
                if hidden, request.model == nil { fields["follow_profile_config"] = true }
            }
            if let parent = request.branchOf {
                let state = try await open(conversationID: parent, sinceSeq: nil)
                fields["parent_session_id"] = parent
                fields["messages"] = state.messages.filter { $0.role == .user || $0.role == .assistant }
                    .map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.content] }
            }
            let result = try await host().chatRPC("session.create", fields).objectValue ?? [:]
            guard let runtimeID = result["session_id"]?.stringValue,
                  let durable = result["stored_session_id"]?.stringValue ?? result["session_key"]?.stringValue else {
                throw ChatRuntimeFailure(.internal)
            }
            bind(conversationID: durable, runtimeID: runtimeID, identity: (request.profile, request.model, nil, request.effort))
            let messages = MessageNormalizer.normalizeMessages(result["messages"]?.arrayValue ?? [])
            return projection(id: durable, result: result, messages: messages)
        }
    }

    func open(conversationID id: String, sinceSeq: UInt64?) async throws -> ChatConversationState {
        try await typed {
            let profile = bindings[id]?.identity.profile
            let raw = try await host().chatResumeObject(id, profile: profile, compact: http != nil)
            guard let runtimeID = raw["session_id"]?.stringValue else { throw ChatRuntimeFailure(.internal) }
            let info = raw["info"]?.objectValue ?? [:]
            bind(conversationID: id, runtimeID: runtimeID,
                 identity: (profile ?? info["profile"]?.stringValue ?? "default", info["model"]?.stringValue,
                            info["provider"]?.stringValue, info["reasoning_effort"]?.stringValue))
            var messages = MessageNormalizer.normalizeMessages(raw["messages"]?.arrayValue ?? [])
            if let http {
                let path = DashboardPath.withProfile("/api/sessions/\(Self.segment(id))/messages?limit=80", profile: profile ?? "default")
                let result = try await http(path)
                guard let rows = AppState.persistedMessageRows(in: result) else { throw ChatRuntimeFailure(.internal) }
                let scope = TranscriptImageScope(sessionId: id, profile: profile ?? "default")
                messages = await Task.detached(priority: .userInitiated) {
                    MessageNormalizer.normalizeMessages(rows.map(AnyCodable.from), imageScope: scope)
                }.value
            }
            var state = projection(id: id, result: raw, messages: messages)
            if let sinceSeq { state.missedEvents = timeline.replay(id, after: sinceSeq) }
            return state
        }
    }

    private func projection(id: String, result: [String: AnyCodable], messages: [ChatMessage]) -> ChatConversationState {
        let info = SessionRuntimeSnapshot(object: result["info"]?.objectValue ?? [:])
        let requests = (result["open_requests"]?.arrayValue ?? []).compactMap { field -> ChatOpenRequest? in
            guard let raw = field.objectValue, let id = raw["id"]?.stringValue, let method = raw["method"]?.stringValue else { return nil }
            if method == "approval" {
                return .init(id: raw["params"]?.objectValue?["request_id"]?.stringValue ?? id, kind: .approval)
            }
            if method == "clarify" { return .init(id: id, kind: .clarify) }
            return InputPromptActivity.Kind(rawValue: method).map { _ in .init(id: id, kind: .secret) }
        }
        return .init(conversationID: id, running: result["running"]?.boolValue ?? info.running ?? false,
                     turnID: timeline.turnID(id), messages: messages, openRequests: requests,
                     context: .init(used: info.contextUsed, window: info.contextMax))
    }

    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    }

    func list(profile: String, limit: Int, cursor: String?, includeArchived: Bool) async throws -> ChatConversationPage {
        try await typed {
            let limit = min(200, max(1, limit))
            let offset = cursor.flatMap(Int.init).flatMap { $0 >= 0 && $0 < Int.max - 200 ? $0 : nil } ?? 0
            let rows: [SessionSummary]
            let archive = includeArchived ? "include" : "exclude"
            if let http, let page = try? await http(DashboardPath.withProfile(
                "/api/profiles/sessions?limit=\(limit)&offset=\(offset)&archived=\(archive)&order=recent", profile: profile)) {
                rows = MessageNormalizer.normalizeSessions(AnyCodable.from(page), profile: profile)
            } else {
                let reply = try await host().chatRPC("session.list", ["profile": profile])
                rows = Array(MessageNormalizer.normalizeSessions(reply, profile: profile)
                    .filter { includeArchived || !$0.isArchived }.dropFirst(offset).prefix(limit))
            }
            let projected = rows.compactMap { row -> ChatConversationRow? in
                guard let id = row.storedSessionId else { return nil }
                return .init(conversationID: id, title: row.title, model: row.model, archived: row.isArchived, pinned: row.isPinned)
            }
            return .init(rows: projected, nextCursor: rows.count == limit ? String(offset + limit) : nil)
        }
    }

    func update(conversationID id: String, title: String?, archived: Bool?, pinned: Bool?) async throws {
        try await typed {
            guard let mutate else { throw ChatRuntimeFailure(.runtimeUnavailable) }
            var patch: [String: Any] = [:]
            patch["title"] = title; patch["archived"] = archived; patch["pinned"] = pinned
            if !patch.isEmpty { try await mutate(id, bindings[id]?.identity.profile ?? "default", patch) }
        }
    }

    func submit(_ request: ChatSubmitRequest) async throws -> ChatAcceptance {
        do {
            switch try await submitForExistingUI(request) {
            case .accepted: return .started
            case .queued: return .queued
            case .steered, .redirected: return .steered
            }
        } catch {
            let failure = HermesChatFailure.failure(error)
            // Compatibility callers do their existing no-resend delivery
            // probe before closing an ambiguous turn. Protocol callers get
            // the typed ambiguity, can reopen, and never get a second write.
            if Self.deliveryMayBeUnknown(error) {
                timeline.fail(request.conversationID, turnID: request.turnID, failure: failure)
            }
            throw failure
        }
    }

    /// Compatibility projection: existing delivery probes need the original
    /// transport/RPC error and the distinction between redirect and steer.
    /// Duplicate ids await the first operation, including ambiguity or failure.
    func submitForExistingUI(_ request: ChatSubmitRequest) async throws -> PromptSubmissionOutcome {
        let id = request.conversationID
        if let previous = submissions[request.turnID] {
            guard previous.conversationID == id else { throw ChatRuntimeFailure(.rejected) }
            return try await previous.task.value
        }
        let binding = try binding(id)
        let task = Task { @MainActor in
            var input = request
            if !request.attachments.isEmpty {
                let refs = try await self.stageAttachments(request.attachments, runtime: binding.runtimeID)
                if !refs.isEmpty { input = ChatSubmitRequest(conversationID: id, turnID: request.turnID,
                                                            text: (refs + [request.text]).joined(separator: " "),
                                                            mode: request.mode, surface: request.surface, voiceTurn: request.voiceTurn) }
            }
            timeline.begin(id, turnID: request.turnID, identity: binding.identity)
            do {
                let outcome = try await sendWire(binding.runtimeID, input)
                switch outcome {
                case .accepted: timeline.accept(id, turnID: request.turnID)
                case .queued: timeline.accept(id, turnID: request.turnID, queued: true)
                case .redirected, .steered: timeline.discardUnstarted(id, turnID: request.turnID)
                }
                return outcome
            } catch {
                if !Self.deliveryMayBeUnknown(error) {
                    timeline.fail(id, turnID: request.turnID, failure: HermesChatFailure.failure(error))
                }
                throw error
            }
        }
        submissions[request.turnID] = Submission(conversationID: id, task: task)
        return try await task.value
    }

    private static func deliveryMayBeUnknown(_ error: Error) -> Bool {
        guard !(error is RpcError) else { return false }
        let code = HermesChatFailure.failure(error).code
        return code == .runtimeUnavailable || code == .timeout || error is CancellationError
    }

    func resolveSubmitProbe(_ request: ChatSubmitRequest, accepted: Bool, settled: Bool, error: Error) {
        if accepted {
            timeline.accept(request.conversationID, turnID: request.turnID)
            if settled { timeline.recoveredSettlement(request.conversationID, turnID: request.turnID) }
        } else {
            timeline.fail(request.conversationID, turnID: request.turnID, failure: HermesChatFailure.failure(error))
        }
    }

    func steer(conversationID id: String, text: String) async throws -> ChatControlStatus {
        try await typed { try await steerForExistingUI(conversationID: id, text: text); return .accepted }
    }

    func steerForExistingUI(conversationID id: String, text: String) async throws {
        _ = try await host().steer(binding(id).runtimeID, text: text)
    }

    func interrupt(conversationID id: String) async throws -> ChatControlStatus {
        try await typed { try await host().cancel(binding(id).runtimeID); return .interrupted }
    }

    func respond(conversationID id: String, requestID: String, answer: ChatRequestAnswer) async throws {
        try await typed {
            let client = try host(), runtimeID = try binding(id).runtimeID
            switch answer {
            case .approval(let choice):
                guard try await client.respondToApproval(sessionId: runtimeID, requestId: requestID, choice: choice) else {
                    throw ChatRuntimeFailure(.rejected)
                }
            case .clarify(let text, let questionID):
                _ = try await client.respondToClarification(requestId: requestID, answer: text, questionId: questionID)
            case .secret(let text): try await client.respondToInputPrompt(requestId: requestID, value: text)
            }
        }
    }

    func set(conversationID id: String, model: String?, provider: String?, effort: String?, confirmed: Bool) async throws -> ChatSettingsResult {
        try await typed {
            let client = try host(), bound = try binding(id)
            var result = ChatSettingsResult(applied: true, confirmRequired: false, model: nil)
            if model != nil || provider != nil {
                guard let model = model ?? bound.identity.model, let provider = provider ?? bound.identity.provider else {
                    throw ChatRuntimeFailure(.rejected)
                }
                let pick = try await client.setModel(bound.runtimeID, model: model, provider: provider, confirmed: confirmed)
                result = .init(applied: !pick.confirmRequired, confirmRequired: pick.confirmRequired,
                               model: pick.model, deferred: pick.deferred, confirmation: pick.confirmMessage)
                if pick.confirmRequired { return result }
            }
            if let effort { try await client.setReasoning(bound.runtimeID, effort: effort) }
            return result
        }
    }

    func setSpeed(conversationID id: String, speed: ModelSpeed) async throws {
        try await typed { try await host().setSpeed(binding(id).runtimeID, speed: speed) }
    }

    func context(conversationID id: String) async throws -> ChatContext {
        try await typed { ChatContext(try await breakdownForExistingUI(conversationID: id)) }
    }

    func breakdownForExistingUI(conversationID id: String) async throws -> ContextBreakdown {
        try await host().contextBreakdown(binding(id).runtimeID)
    }

    func compact(conversationID id: String, focus: String?) async -> ContextCompactResult {
        do {
            return try await compactForExistingUI(conversationID: id, focus: focus).1
        } catch { return .init(status: .failed, failure: HermesChatFailure.failure(error)) }
    }

    func compactForExistingUI(conversationID id: String, focus: String?) async throws -> (SessionCompressResult, ContextCompactResult) {
        let runtimeID = try binding(id).runtimeID
        let before = try? await context(conversationID: id)
        let receipt = try await host().compressSession(sessionId: runtimeID, focusTopic: focus)
        let after: ChatContext?
        if receipt.isPending || receipt.lockHeld { after = nil }
        else { after = try? await context(conversationID: id) }
        return (receipt, HermesChatCompaction.resolve(receipt, before: before, after: after))
    }

    func addAttachment(conversationID id: String, kind: ChatAttachment.Kind, name: String, data: Data) async throws -> String {
        try await typed {
            guard let ref = try await add(kind, name: name, data: data, runtime: binding(id).runtimeID) else {
                throw ChatRuntimeFailure(.internal)
            }
            return ref
        }
    }

    private func add(_ kind: ChatAttachment.Kind, name: String, data: Data, runtime: String) async throws -> String? {
        switch kind {
        case .image: return try await host().attachImage(runtime, base64: data.base64EncodedString(), filename: name)
        case .file: return try await host().attachFile(runtime, dataUrl: "data:application/octet-stream;base64,\(data.base64EncodedString())", name: name)
        }
    }

    private func stageAttachments(_ attachments: [ChatAttachment], runtime: String) async throws -> [String] {
        var files: [String] = [], images: [String] = []
        do {
            for item in attachments {
                guard let ref = try await add(item.kind, name: item.name, data: item.data, runtime: runtime) else {
                    throw ChatRuntimeFailure(.internal)
                }
                switch item.kind { case .file: files.append(ref); case .image: images.append(ref) }
            }
            return files
        } catch {
            for path in images { try? await host().detachImage(runtime, path: path) }
            throw error
        }
    }
}
#endif
