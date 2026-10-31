import Foundation

@main private struct RangeVersionFixture {
    static func main() async throws {
        let credentials = LAABridgeCredentials(baseURL: URL(string: CommandLine.arguments[1])!,
                                                deviceID: "fixture", token: "fixture-token")
        let client = LAABridgeClient()
        func read(_ id: String, version: String? = nil) async throws -> LAADriveRangeResponse {
            try await client.driveRange(path: "/v1/drive/files/\(id)/content", credentials: credentials,
                                        offset: 0, length: 4, expectedVersion: version)
        }
        let correct = try await read("file_good", version: "42")
        precondition(correct.data == Data("test".utf8) && correct.version == "42" && correct.total == 4)
        let old = try await read("file_old")
        precondition(old.version == nil && old.data == Data("test".utf8))
        for id in ["file_changed", "file_old"] {
            do { _ = try await read(id, version: "42"); fatalError("expected version mismatch") }
            catch LAADriveRangeError.versionChanged { }
        }
        do { _ = try await read("file_bad"); fatalError("expected invalid version") }
        catch LAADriveRangeError.invalidRange { }
        do { _ = try await read("file_good", version: "x"); fatalError("expected invalid expected version") }
        catch LAABridgeError.invalidAddress { }
        print("Drive authenticated range version fixture passed")
    }
}
