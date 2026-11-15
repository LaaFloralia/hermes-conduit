#if DEBUG
import SwiftUI

/// Reads the production hosted-room log through a loopback-only read adapter.
/// The existing notification coordinator, replay and GroupChatView are used.
/// This fixture neither sends a chat turn nor replaces a saved connection.
@MainActor
struct RoutineRoomLiveFixture: View {
    static let launchArgument = "-ROUTINE_ROOM_LIVE_FIXTURE"
    @StateObject private var state: AppState
    @State private var status = "Loading"

    init() {
        let defaults = UserDefaults(suiteName: "RoutineRoomLiveFixture")!
        let dashboard = SavedDashboard(id: UUID(), label: "Routine read adapter", normalizedURL: "http://127.0.0.1:19739")
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in GroupCapabilities(protocolVersion: 2, driverReady: false,
                authorityGatewayID: "fixture", features: [], methods: GroupWire.requiredMethods, maxLogLimit: 500) },
            list: { _ in ([try await Self.room()], nil) },
            state: { _, _ in (try await Self.room(), nil) },
            log: { _, _, since, _ in
                let payload = try await Self.read("events?since=\(since)")
                guard let page = GroupDecoders.logPage(payload) else { throw URLError(.cannotParseResponse) }
                return page
            })
        let state = AppState(defaults: defaults, loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]),
            clearSessionPresentationCache: {}, groupChatOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults))
        let connection = HermesConnection(baseUrl: dashboard.normalizedURL, ticket: "loopback-read-only")
        state.connection = connection
        state.client = HermesClient(connection: connection, profile: "default")
        state.isConnected = true
        _state = StateObject(wrappedValue: state)
    }

    private static func read(_ path: String) async throws -> AnyCodable {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:19739/" + path)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    private static func room() async throws -> GroupRoom {
        guard let room = GroupDecoders.room(try await read("room")) else { throw URLError(.cannotParseResponse) }
        return room
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(status).accessibilityIdentifier("routine.live.status")
            GroupChatView().environmentObject(state)
        }
        .task {
            do {
                let payload = try await Self.read("target")
                guard let id = payload.objectValue?["session_id"]?.stringValue else { throw URLError(.cannotParseResponse) }
                let target = ConduitNotificationTarget(profile: "laa-monet", sessionId: id,
                    dashboardID: state.activeDashboardID, type: "response.ready")
                let outcome = await state.openNotificationTargetOutcome(target)
                status = outcome == .opened ? "定期実行 · 保存済み報告を表示" : "Route failed"
            } catch { status = "Read failed" }
        }
    }
}
#endif
