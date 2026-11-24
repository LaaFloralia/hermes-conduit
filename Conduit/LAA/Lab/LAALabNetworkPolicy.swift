#if DEBUG
import Foundation

/// Debug test processes share the host's loopback. Loopback alone does not
/// identify a fixture, and a response header cannot undo a transmitted write.
struct LAALabNetworkPolicy {
    static let header = "X-LAA-Lane"
    static let current = Self(environment: ProcessInfo.processInfo.environment,
                              arguments: ProcessInfo.processInfo.arguments)
    private let environment: [String: String]
    let isActive: Bool
    var laneID: String? { environment["LAA_LANE_ID"] }
    var bridgeAddress: String? { environment["LAA_BRIDGE_DEFAULT_ADDRESS"] ?? environment["LAA_LANE_BRIDGE"] }

    init(environment: [String: String], arguments: [String] = []) {
        self.environment = environment
        isActive = environment["LAA_LANE_ID"] != nil || environment["CONDUIT_UITEST"] == "1"
            || arguments.contains("-LAA_UI_TEST_ISOLATED_BRIDGE") || environment["LAA_BRIDGE_DEFAULT_ADDRESS"] != nil
    }

    private static let productionPorts: Set<Int> = [9137, 9119, 8443, 8444, 8445, 8384, 8081]
    private static let unreachablePort = 1
    private static let legacyBridgePorts: Set<Int> = [unreachablePort, 19414, 19491, 19492, 19582, 19584, 19593, 19596, 19684]

    private func loopbackPort(_ url: URL?, websocket: Bool = false) -> Int? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "http" || (websocket && parts.scheme == "ws"),
              let host = parts.host, ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host),
              parts.user == nil, parts.password == nil, let port = parts.port,
              (1...65535).contains(port), !Self.productionPorts.contains(port) else { return nil }
        return port
    }

    private func sameEndpoint(_ url: URL?, _ configured: String?, websocket: Bool = false) -> Bool {
        guard let url, let configured, let fixture = URL(string: configured),
              let port = loopbackPort(url, websocket: websocket), port == loopbackPort(fixture),
              url.host == fixture.host else { return false }
        return true
    }

    func allowsBridge(_ url: URL?) -> Bool {
        guard isActive else { return true }
        guard let port = loopbackPort(url) else { return false }
        if laneID != nil {
            // Port 1 is the "Mac is unreachable" fixture: nothing listens there,
            // so the request ends as a refused connection, not as a lane error.
            return (port == Self.unreachablePort && url?.host == "127.0.0.1")
                || sameEndpoint(url, environment["LAA_LANE_BRIDGE"])
                || environment.contains { key, value in
                    key.hasPrefix("LAA_LANE_FIXTURE_") && sameEndpoint(url, value)
                }
        }
        return Self.legacyBridgePorts.contains(port) || sameEndpoint(url, bridgeAddress)
    }

    func allowsHermes(_ url: URL?) -> Bool {
        !isActive || sameEndpoint(url, environment["LAA_LANE_HERMES"], websocket: true)
    }

    var allowsPush: Bool { !isActive }

    func acceptsBridgeResponse(_ response: HTTPURLResponse) -> Bool {
        guard let laneID else { return true }
        return validLaneID && response.statusCode != 421 && response.value(forHTTPHeaderField: Self.header) == laneID
    }

    private var validLaneID: Bool {
        guard let laneID else { return true }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return (1...96).contains(laneID.utf8.count) && laneID.unicodeScalars.allSatisfy(allowed.contains)
    }

    #if LAA_BUILD
    func stampBridgeRequest(_ request: inout URLRequest) throws {
        guard allowsBridge(request.url), validLaneID else { throw LAABridgeError.laneMismatch }
        if let laneID { request.setValue(laneID, forHTTPHeaderField: Self.header) }
    }

    func verifyBridgeResponse(_ response: URLResponse) throws {
        guard laneID != nil else { return }
        guard let http = response as? HTTPURLResponse, acceptsBridgeResponse(http) else {
            throw LAABridgeError.laneMismatch
        }
    }
    #endif
}
#endif
