#if LAA_BUILD
import Foundation

struct LAAMeetingGrant: Decodable, Equatable {
    let roomId: String
    let endpointId: String
    let generation: String
    let expiresAt: Int64
    let remainingMs: Int
}

struct LAAMeetingLeaseClient {
    struct Request: Encodable {
        let action: String
        let endpointId: String
        var generation: String?
        var pulse: Int?
    }
    struct Released: Decodable { let released: Bool }

    var request: @MainActor (String, Request) async throws -> LAAMeetingGrant?

    static func bridge() throws -> Self {
        guard let credentials = try LAABridgeKeychain().read() else { throw CancellationError() }
        let client = LAABridgeClient()
        return Self { room, request in
            guard room.range(of: #"\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z"#, options: .regularExpression) != nil else {
                throw CancellationError()
            }
            let path = "/v1/meetings/\(room)/audio-lease"
            let body = try JSONEncoder().encode(request)
            if request.action == "release" {
                let _: LAABridgeResponse<Released> = try await client.request(
                    method: "POST", path: path, jsonBody: body, credentials: credentials, timeout: 4)
                return nil
            }
            let result: LAABridgeResponse<LAAMeetingGrant> = try await client.request(
                method: "POST", path: path, jsonBody: body, credentials: credentials, timeout: 4)
            return result.data
        }
    }
}

/// One explicit claim per local attempt; only a live matching generation can
/// open either audio edge. Monotonic deadlines are conservative even if the
/// Bridge clock changes or a response is slow. Cancellation never reclaims.
@MainActor
final class LAAMeetingEndpoint {
    private struct Active {
        let grant: LAAMeetingGrant
        let deadline: ContinuousClock.Instant
        let client: LAAMeetingLeaseClient
    }
    private var active: Active?
    private var attempt: UUID?
    private var heartbeat: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private let clock = ContinuousClock()
    var onLoss: (() -> Void)?
    var generation: String? { active?.grant.generation }
    var canUseAudio: Bool { active.map { clock.now < $0.deadline } ?? false }

    func claim(room: String, using client: LAAMeetingLeaseClient) async throws -> Bool {
        guard attempt == nil, active == nil else { return false }
        let id = UUID()
        attempt = id
        defer { if attempt == id { attempt = nil } }
        let endpoint = id.uuidString.lowercased()
        let sent = clock.now
        guard let grant = try await client.request(room, .init(action: "claim", endpointId: endpoint)),
              grant.roomId == room, grant.endpointId == endpoint else { return false }
        guard attempt == id, !Task.isCancelled, accept(grant, client: client, sent: sent) else {
            Self.release(grant, client: client)
            return false
        }
        startHeartbeat(id: grant.generation)
        return true
    }

    func leave() {
        attempt = nil
        heartbeat?.cancel()
        heartbeat = nil
        expiry?.cancel()
        expiry = nil
        if let active { Self.release(active.grant, client: active.client) }
        active = nil
    }

    private static func release(_ grant: LAAMeetingGrant, client: LAAMeetingLeaseClient) {
        Task { @MainActor in
            _ = try? await client.request(grant.roomId, .init(action: "release", endpointId: grant.endpointId,
                                                             generation: grant.generation))
        }
    }

    private func accept(_ grant: LAAMeetingGrant, client: LAAMeetingLeaseClient, sent: ContinuousClock.Instant) -> Bool {
        guard (501...12_000).contains(grant.remainingMs) else { return false }
        let deadline = sent.advanced(by: .milliseconds(grant.remainingMs - 500))
        guard clock.now < deadline else { return false }
        active = Active(grant: grant, deadline: deadline, client: client)
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: ContinuousClock())
            guard !Task.isCancelled, let self else { return }
            self.lose(grant.generation)
        }
        return true
    }

    private func startHeartbeat(id: String) {
        heartbeat = Task { [weak self] in
            var pulse = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, let active = self.active, active.grant.generation == id else { return }
                guard self.canUseAudio else { self.lose(id); return }
                pulse += 1
                let sent = self.clock.now
                do {
                    let next = try await active.client.request(active.grant.roomId, .init(
                        action: "renew", endpointId: active.grant.endpointId, generation: id, pulse: pulse))
                    guard !Task.isCancelled, self.generation == id else { return }
                    guard let next, next.generation == id, next.roomId == active.grant.roomId,
                          next.endpointId == active.grant.endpointId, self.canUseAudio,
                          self.accept(next, client: active.client, sent: sent) else {
                        self.lose(id)
                        return
                    }
                } catch {
                    self.lose(id)
                    return
                }
            }
        }
    }

    private func lose(_ id: String) {
        guard generation == id else { return }
        // Stop local audio synchronously before letting the server give the
        // room to another endpoint. `leave()` in the callback is harmless.
        onLoss?()
        if generation == id { leave() }
    }
}
#endif
