import Foundation

private func expect(_ value: Bool, _ message: String) {
    guard value else { fatalError(message) }
}

private func expectError<T: Error & Equatable>(_ expected: T, _ run: () async throws -> Void) async {
    do { try await run(); fatalError("expected \(expected)") }
    catch let error as T { expect(error == expected, "expected \(expected), got \(error)") }
    catch { fatalError("unexpected error: \(error)") }
}

@main private struct ThumbnailFixture {
    static func main() async throws {
        let credentials = LAABridgeCredentials(baseURL: URL(string: CommandLine.arguments[1])!,
                                               deviceID: "fixture", token: "fixture-token")
        let client = LAABridgeClient()
        let png = try await client.driveThumbnail(id: "file_1", credentials: credentials)
        expect(png.starts(with: [0x89, 0x50, 0x4e, 0x47]), "valid thumbnail")
        await expectError(LAABridgeError.invalidResponse) { _ = try await client.driveThumbnail(id: "../etc", credentials: credentials) }
        await expectError(LAABridgeError.invalidResponse) { _ = try await client.driveThumbnail(id: "file_bad", credentials: credentials) }
        await expectError(LAABridgeError.invalidResponse) { _ = try await client.driveThumbnail(id: "file_wrongmime", credentials: credentials) }
        await expectError(LAADriveThumbnailError.tooLarge) { _ = try await client.driveThumbnail(id: "file_big", credentials: credentials) }
        await expectError(LAADriveThumbnailError.tooLarge) { _ = try await client.driveThumbnail(id: "file_streambig", credentials: credentials) }
        do {
            _ = try await client.driveThumbnail(id: "file_denied", credentials: credentials)
            fatalError("expected 404")
        } catch let error as LAABridgeHTTPError {
            expect(error.status == 404 && error.code == "thumbnail_unavailable", "HTTP error code preserved")
        }
        do {
            _ = try await client.driveThumbnail(id: "file_redirect", credentials: credentials)
            fatalError("expected redirect refusal")
        } catch let error as LAABridgeHTTPError { expect(error.status == 302, "redirect refused") }
        let slow = Task { try await client.driveThumbnail(id: "file_slow", credentials: credentials) }
        try await Task.sleep(for: .milliseconds(200))
        slow.cancel()
        do { _ = try await slow.value; fatalError("expected cancellation") } catch is CancellationError { }

        let cache = LAADriveThumbnailCache(maximumBytes: 8, maximumEntries: 2)
        let a = LAADriveThumbnailKey(pairingID: "device1", fileID: "file_1", version: "1")!
        let b = LAADriveThumbnailKey(pairingID: "device1", fileID: "file_2", version: "1")!
        let c = LAADriveThumbnailKey(pairingID: "device1", fileID: "file_3", version: "1")!
        let otherDevice = LAADriveThumbnailKey(pairingID: "device2", fileID: "file_1", version: "1")!
        let newer = LAADriveThumbnailKey(pairingID: "device1", fileID: "file_1", version: "2")!
        expect(LAADriveThumbnailKey(pairingID: "device1", fileID: "file_1", version: nil) == nil, "version required")
        expect(LAADriveThumbnailKey(pairingID: "device1", fileID: "../etc", version: "1") == nil, "valid file ID required")
        await cache.insert(Data([1, 2, 3]), for: a)
        await cache.insert(Data([4, 5, 6]), for: b)
        let hitA = await cache.value(for: a)
        let missNew = await cache.value(for: newer)
        let missDevice = await cache.value(for: otherDevice)
        expect(hitA == Data([1, 2, 3]) && missNew == nil && missDevice == nil, "version and device isolation")
        await cache.insert(Data([7, 8, 9]), for: c)
        let hitRecent = await cache.value(for: a)
        let evicted = await cache.value(for: b)
        expect(hitRecent != nil && evicted == nil, "least recently used entry evicted")
        await cache.insert(Data(repeating: 0, count: 9), for: a)
        let oversized = await cache.value(for: a)
        expect(oversized == nil, "oversized replacement not retained")
        await cache.insert(Data([1]), for: a)
        await cache.insert(Data([2]), for: newer)
        await cache.invalidate(pairingID: "device1", fileID: "file_1")
        let revoked = await cache.value(for: a)
        let revokedNew = await cache.value(for: newer)
        expect(revoked == nil && revokedNew == nil, "known revocation invalidates all versions")
        await cache.insert(Data([1]), for: otherDevice)
        await cache.removeAll()
        let cleared = await cache.value(for: otherDevice)
        expect(cleared == nil, "pairing reset clears cache")

        let byteLimited = LAADriveThumbnailCache(maximumBytes: 8, maximumEntries: 4)
        await byteLimited.insert(Data([1, 2, 3]), for: a)
        await byteLimited.insert(Data([4, 5, 6]), for: b)
        await byteLimited.insert(Data([7, 8, 9]), for: c)
        let byteEvicted = await byteLimited.value(for: a)
        let byteKept = await byteLimited.value(for: b)
        expect(byteEvicted == nil && byteKept != nil, "byte limit evicts even below the entry limit")
        print("Drive thumbnail client and cache fixture passed")
    }
}
