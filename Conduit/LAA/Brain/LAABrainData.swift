#if LAA_BUILD
import Foundation

/// One Bridge connection for the whole app; the DEBUG fixture exists only so
/// UI tests can exercise the screen without a live vault or a device token.
enum LAABrainData {
    #if DEBUG
    @MainActor private static var fixtureWrites = 0
    @MainActor private(set) static var fixtureSubmittedContent: String?
    @MainActor static var fixtureMarkedAtSave = false
    static var isTestFixture: Bool { fixture != nil }
    static var isMarkedTextFixture: Bool { fixture == "marked" }
    #endif
    private static var fixture: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-laa-brain-fixture"), index + 1 < args.count { return args[index + 1] }
        #endif
        return nil
    }

    @MainActor static func available(_ bridge: LAABridgeSession) -> Bool {
        bridge.status == .paired || fixture != nil
    }

    @MainActor static func deviceID(_ bridge: LAABridgeSession) -> String? {
        if fixture != nil { return "fixture-device" }
        return bridge.deviceID
    }

    @MainActor static func read<T: Decodable>(_ route: String, bridge: LAABridgeSession) async throws -> T {
        #if DEBUG
        if let fixture { return try fixtureRead(route, mode: fixture) }
        #endif
        return try await bridge.read(route)
    }

    @MainActor static func write<T: Decodable>(body: Data, key: LAABridgeIdempotencyKey,
                                               bridge: LAABridgeSession) async throws -> T {
        #if DEBUG
        if let fixture {
            if fixture == "uncertain" {
                fixtureWrites += 1
                if fixtureWrites == 1 { throw LAABridgeError.networkUnreachable }
                throw LAABridgeHTTPError(status: 403, code: "scope_required", message: nil,
                                         retryable: false, details: nil, requestId: nil, currentETag: nil)
            }
            let request = try JSONDecoder().decode(FixtureCreate.self, from: body)
            if fixture == "marked" { fixtureSubmittedContent = request.content }
            let actual = String(request.path.dropLast(3)) + " 2.md"
            return try decode(["id": LAABrainReference(path: actual, includeInbox: true).id,
                               "path": actual, "suffixApplied": true])
        }
        #endif
        let response: LAABridgeResponse<T> = try await bridge.request(
            method: "POST", path: "/v1/brain/files", jsonBody: body, idempotencyKey: key)
        return response.data
    }

    #if DEBUG
    private struct FixtureCreate: Decodable { let path: String; let content: String }
    private static func decode<T: Decodable>(_ object: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private static func fixtureRead<T: Decodable>(_ route: String, mode: String) throws -> T {
        if mode == "offline" { throw LAABridgeError.networkUnreachable }
        if mode == "failed" { throw LAABridgeError.other(status: 500, code: "fixture") }
        guard let url = URLComponents(string: route) else { throw LAABridgeError.invalidResponse }
        let first = "Company/Start.md", second = "Company/Other.md"
        let firstID = LAABrainReference(path: first, includeInbox: false).id
        let secondID = LAABrainReference(path: second, includeInbox: false).id
        var items: [[String: Any]] = mode == "empty" ? [] : [
            ["id": firstID, "path": first, "title": "Start", "modifiedAt": "2026-10-29T00:00:00.000Z", "area": "company"],
            ["id": secondID, "path": second, "title": "Other", "modifiedAt": "2026-10-28T00:00:00.000Z", "area": "company"],
        ]
        if mode == "many" {
            for number in 3...4 {
                let path = "Company/Note \(number).md"
                items.append(["id": LAABrainReference(path: path, includeInbox: false).id,
                              "path": path, "title": "Note \(number)",
                              "modifiedAt": "2026-10-2\(9 - number)T00:00:00.000Z", "area": "company"])
            }
        }
        switch url.path {
        case "/v1/me": return try decode(["scopes": mode == "denied" ? ["brain:read"] : ["brain:read", "brain:create"]])
        case "/v1/brain/files": return try decode(["items": items, "nextCursor": NSNull()])
        case "/v1/brain/search":
            let hits: [[String: Any]] = mode == "empty" ? [] : [["path": first, "section": "見出し", "text": "検索できる本文です。"]]
            return try decode(["results": hits])
        case "/v1/brain/files/" + firstID:
            return try decode(["id": firstID, "path": first, "text": "---\nstatus: draft\n---\n# 見出し\n\n- [x] 確認\n\n[[Other|次のメモ]]\n\n![図](images/example.png)\n\n::: unknown\n"])
        case "/v1/brain/files/" + secondID:
            return try decode(["id": secondID, "path": second, "text": "# 別のメモ\n\n内容です。"])
        default: throw LAABridgeError.other(status: 404, code: "not_found")
        }
    }
    #endif
}
#endif
