#if LAA_BUILD
import Foundation

@MainActor struct HermesChatProjectRuntime: LAAChatProjectRuntime {
    let connectedClient: () -> HermesClient?

    func create(_ request: LAAChatProjectCreate) async throws {
        guard let client = connectedClient(), client.laaHasChatProjects else {
            throw LAAChatProjectFailure(.runtimeUnavailable)
        }
        let wire: AnyCodable
        do {
            wire = try await client.laaProjectRPC("laa.projects.create", params: identity(request.route).merging([
                "conversation_id": request.conversationID.uuidString, "title": request.title, "hidden": request.hidden
            ]) { current, _ in current })
        } catch { throw Self.rpcFailure(error) }
        guard wire.objectValue?["conversation_id"]?.stringValue.flatMap(UUID.init(uuidString:)) == request.conversationID else {
            throw LAAChatProjectFailure(.runtimeUnavailable)
        }
    }

    func submit(_ request: LAAChatProjectSubmit) -> AsyncThrowingStream<LAAChatProjectEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let client = connectedClient(), client.laaHasChatProjects else {
                continuation.finish(throwing: LAAChatProjectFailure(.runtimeUnavailable)); return
            }
            let relay = Relay(request: request, continuation: continuation)
            client.laaProjectEventHandlers[request.turnID] = { relay.receive($0) }
            let payload = identity(request.route).merging([
                "conversation_id": request.conversationID.uuidString, "turn_id": request.turnID.uuidString,
                "system": request.system, "text": request.text,
                "history": request.history.map { ["role": $0.role.rawValue, "text": $0.text] }
            ]) { current, _ in current }
            let send = Task { @MainActor in
                do {
                    let ack = try await client.laaProjectRPC("laa.projects.submit", params: payload)
                    guard ack.objectValue?["accepted"]?.stringValue == "started" else { return }
                    continuation.yield(.accepted)
                } catch let error as RpcError {
                    // These are authoritative pre-delivery refusals. For any
                    // transport failure the replay loop probes, never resends.
                    continuation.finish(throwing: Self.rpcFailure(error))
                } catch { }
            }
            let recover = Task { @MainActor in
                let deadline = ContinuousClock.now + .seconds(120)
                while !Task.isCancelled, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .seconds(6))
                    guard !Task.isCancelled else { return }
                    guard let latest = connectedClient() else { continue }
                    let wire = try? await Self.readEvents(latest, conversation: request.conversationID,
                                                          turn: request.turnID, after: relay.sequence)
                    wire?.forEach { relay.receive($0) }
                }
                if !Task.isCancelled { continuation.finish(throwing: LAAChatProjectFailure(.unknownDelivery)) }
            }
            continuation.onTermination = { _ in
                send.cancel(); recover.cancel()
                Task { @MainActor [weak client] in client?.laaProjectEventHandlers[request.turnID] = nil }
            }
        }
    }

    func replay(conversationID: UUID, turnID: UUID) async throws -> [LAAChatProjectEvent] {
        guard let client = connectedClient() else { throw LAAChatProjectFailure(.runtimeUnavailable) }
        let events = try await Self.readEvents(client, conversation: conversationID, turn: turnID, after: nil)
        return events.compactMap { object in
            guard Self.matches(object, conversation: conversationID, turn: turnID) else { return nil }
            return Self.decode(object)
        }
    }

    private static func readEvents(_ client: HermesClient, conversation: UUID, turn: UUID,
                                   after: Int?) async throws -> [[String: AnyCodable]] {
        var params: [String: Any] = ["conversation_id": conversation.uuidString, "turn_id": turn.uuidString]
        if let after { params["since_seq"] = after }
        let wire = try await client.laaProjectRPC("laa.projects.replay", params: params)
        guard let events = wire.objectValue?["events"]?.arrayValue else { return [] }
        return events.compactMap(\.objectValue)
    }

    private func identity(_ route: LAAChatProjectRoute) -> [String: Any] {
        ["profile": LAAChatProjectCreate.profile, "model": route.model, "provider": route.provider, "effort": route.effort]
    }

    private static func rpcFailure(_ error: Error) -> LAAChatProjectFailure {
        if let rpc = error as? RpcError, let reason = rpc.reason, let code = LAAChatProjectFailure.Code(rawValue: reason) {
            return .init(code)
        }
        return .init(.runtimeUnavailable)
    }

    private static func matches(_ wire: [String: AnyCodable], conversation: UUID, turn: UUID) -> Bool {
        wire["conversation_id"]?.stringValue.flatMap(UUID.init(uuidString:)) == conversation &&
            wire["turn_id"]?.stringValue.flatMap(UUID.init(uuidString:)) == turn
    }

    static func decode(_ wire: [String: AnyCodable]) -> LAAChatProjectEvent? {
        let data = wire["data"]?.objectValue ?? [:]
        switch wire["type"]?.stringValue {
        case "turn.started":
            guard let model = data["model"]?.stringValue, let provider = data["provider"]?.stringValue,
                  let effort = data["effort"]?.stringValue else { return nil }
            return .started(.init(model: model, provider: provider, effort: effort))
        case "text.delta": return data["text"]?.stringValue.map(LAAChatProjectEvent.text)
        case "turn.completed": return .completed(data["text"]?.stringValue ?? "")
        case "turn.failed":
            let code = data["code"]?.stringValue.flatMap(LAAChatProjectFailure.Code.init(rawValue:)) ?? .internalError
            let retry = data["retry_at"]?.stringValue.flatMap { value in
                (try? Date(value, strategy: .iso8601)) ??
                    (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            }
            return .failed(.init(code, retryAt: retry))
        default: return nil
        }
    }

    @MainActor private final class Relay {
        let request: LAAChatProjectSubmit
        let continuation: AsyncThrowingStream<LAAChatProjectEvent, Error>.Continuation
        private(set) var sequence: Int?

        init(request: LAAChatProjectSubmit, continuation: AsyncThrowingStream<LAAChatProjectEvent, Error>.Continuation) {
            self.request = request; self.continuation = continuation
        }

        func receive(_ object: [String: AnyCodable]) {
            guard matches(object, conversation: request.conversationID, turn: request.turnID),
                  let seq = object["seq"]?.intValue else { return }
            if let sequence { guard seq == sequence + 1 else { return } }
            // First event can be any sequence for this conversation, but it
            // must be the turn's start or a failure before provider start.
            else if !["turn.started", "turn.failed"].contains(object["type"]?.stringValue ?? "") { return }
            sequence = seq
            guard let event = decode(object) else { return }
            continuation.yield(event)
            switch event {
            case .completed, .failed: continuation.finish()
            default: break
            }
        }
    }
}
#endif
