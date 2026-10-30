#if LAA_BUILD
import XCTest
import Network
import CryptoKit
@testable import Conduit

final class LAADriveRangeTests: XCTestCase {
    func testSeekMiddleAnd416AndIgnoredRange() async throws {
        let server = try await DriveRangeServer.start()
        defer { server.stop() }
        let credentials = LAABridgeCredentials(baseURL: server.url, deviceID: "test", token: "test-token")
        let client = LAABridgeClient()
        let part = try await client.driveRange(path: "/v1/drive/files/seek01/content", credentials: credentials, offset: 500, length: 100)
        XCTAssertEqual(part.total, 1000)
        XCTAssertEqual(part.data, Data((500..<600).map { UInt8($0 % 251) }))
        XCTAssertEqual(server.lastRange, "bytes=500-599")
        XCTAssertTrue(server.sawTestAuthorization)
        do {
            _ = try await client.driveRange(path: "/v1/drive/files/outside01/content", credentials: credentials, offset: 1000, length: 10)
            XCTFail("416 must fail")
        } catch let error as LAADriveRangeError { XCTAssertEqual(error, .unsatisfiable) }
        do {
            _ = try await client.driveRange(path: "/v1/drive/files/ignore01/content", credentials: credentials, offset: 500, length: 100)
            XCTFail("200 must not be treated as a partial response")
        } catch let error as LAADriveRangeError { XCTAssertEqual(error, .rangeUnsupported) }
    }

    func testCancellationStopsAnInFlightRange() async throws {
        let server = try await DriveRangeServer.start()
        defer { server.stop() }
        let credentials = LAABridgeCredentials(baseURL: server.url, deviceID: "test", token: "test-token")
        let task = Task {
            try await LAABridgeClient().driveRange(path: "/v1/drive/files/slow01/content", credentials: credentials, offset: 0, length: 1000)
        }
        try await server.waitForSlowRequest()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request must not return data") }
        catch is CancellationError { }
        try await server.waitForClose()
    }

    @MainActor func testLongPlayerSeeksWithBoundedRanges() async throws {
        let fixtures = try VirtualDriveMedia.loadFixtures()
        let media = try XCTUnwrap(fixtures[240])
        let server = try await DriveRangeServer.start(media: ["long01": media])
        defer { server.stop() }
        let credentials = LAABridgeCredentials(baseURL: server.url, deviceID: "test", token: "test-token")
        let bridge = LAABridgeSession(credentialsForTesting: credentials)
        let data = Data("""
        {"id":"long01","name":"Long video","mimeType":"video/mp4","kind":"file","downloadable":true}
        """.utf8)
        let item = try JSONDecoder().decode(LAADriveItem.self, from: data)
        let player = LAADrivePlayer(item: item, bridge: bridge)
        defer { player.close() }
        XCTAssertEqual(player.player.currentItem?.preferredForwardBufferDuration, 15)
        player.toggle()
        let duration = try await waitForDuration(player)
        XCTAssertEqual(duration, 240, accuracy: 1)
        try await server.waitForPendingMedia("long01")
        let before = server.mediaRequests("long01")
        // Include cancelled requests: their announced lengths are an upper
        // bound on bytes actually delivered by the fake server.
        let beforeBytes = before.reduce(0) { $0 + $1.length }
        // 15 s at the fixture bitrate is about 2.5 MB. The controlled server
        // permits some metadata/prefetch overhead but never an entire download.
        XCTAssertLessThanOrEqual(beforeBytes, 4 * 1024 * 1024)
        XCTAssertTrue(before.allSatisfy { $0.length <= LAADriveContent.chunkSize })
        XCTAssertNil(player.error)
        let pendingBeforeSeek = server.pendingMediaIDs("long01")
        XCTAssertFalse(pendingBeforeSeek.isEmpty)
        player.seek(duration / 2)
        try await server.waitForMiddleMediaRequest("long01", after: before.count, total: media.size)
        try await server.waitForCancelledMedia("long01", among: pendingBeforeSeek)
        try await Task.sleep(for: .milliseconds(500))
        player.close()
        let all = server.mediaRequests("long01")
        let after = all.dropFirst(before.count)
        XCTAssertTrue(after.contains { $0.start > media.size * 35 / 100 && $0.start < media.size * 65 / 100 })
        XCTAssertTrue(all.allSatisfy { $0.length <= LAADriveContent.chunkSize })
        XCTAssertLessThan(all.reduce(0) { $0 + $1.length }, media.size)
        XCTAssertNil(player.error)
    }

    @MainActor func testShortPlayerDoesNotDownloadAgainAfterSeek() async throws {
        let media = try XCTUnwrap(VirtualDriveMedia.loadFixtures()[30])
        let server = try await DriveRangeServer.start(media: ["short01": media])
        defer { server.stop() }
        let credentials = LAABridgeCredentials(baseURL: server.url, deviceID: "test", token: "test-token")
        let bridge = LAABridgeSession(credentialsForTesting: credentials)
        let item = try JSONDecoder().decode(LAADriveItem.self, from: Data("""
        {"id":"short01","name":"Short video","mimeType":"video/mp4","kind":"file","downloadable":true}
        """.utf8))
        let player = LAADrivePlayer(item: item, bridge: bridge)
        defer { player.close() }
        player.toggle()
        let duration = try await waitForDuration(player)
        let before = server.mediaRequests("short01").count
        player.seek(duration / 2)
        // A short file may already be buffered, so a new Range is optional.
        try await Task.sleep(for: .seconds(1))
        player.close()
        let all = server.mediaRequests("short01")
        let afterBytes = all.dropFirst(before).reduce(0) { $0 + $1.length }
        XCTAssertLessThan(afterBytes, media.size)
        XCTAssertLessThanOrEqual(all.reduce(0) { $0 + $1.length }, media.size)
        XCTAssertNil(player.error)
    }

    @MainActor private func waitForDuration(_ player: LAADrivePlayer) async throws -> Double {
        for _ in 0..<400 {
            let duration = player.player.currentItem?.duration.seconds ?? 0
            if duration.isFinite && duration > 1 { return duration }
            if player.error != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(domain: "Drive player duration timeout", code: 1)
    }

    func testUnsafeIDsAndMalformedRangesAreRejected() throws {
        XCTAssertThrowsError(try LAADrivePaths.content("../other"))
        XCTAssertNil(LAABridgeClient.parseDriveRange("bytes 5-100/50"))
        XCTAssertNil(LAABridgeClient.parseDriveRange("bytes 5-8/*"))
        XCTAssertNil(LAABridgeClient.parseDriveRange("bytes 9-5/100"))
        XCTAssertNil(LAADriveThumbnail.safeURL(URL(string: "https://example.com/image")))
        XCTAssertNotNil(LAADriveThumbnail.safeURL(URL(string: "https://lh3.googleusercontent.com/image")))
    }
}

/// The fast-start MP4 headers describe 15 and 120 stream-copied repetitions
/// of the bundled two-second Ciel video (ffmpeg `-stream_loop`, `-c copy`,
/// `-movflags +faststart`). Only the requested slice is assembled in memory.
private struct VirtualDriveMedia {
    private struct Fixtures: Decodable {
        struct File: Decodable { let durationSeconds: Int; let repetitions: Int; let header: String }
        let payloadLength: Int
        let payloadSHA256: String
        let files: [File]
    }
    let header: Data
    let payload: Data
    let repetitions: Int
    var size: Int { header.count + payload.count * repetitions }

    static func loadFixtures() throws -> [Int: VirtualDriveMedia] {
        let fixturesURL = try XCTUnwrap(Bundle(for: LAADriveRangeTests.self).url(forResource: "laa-drive-seek-fixtures", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: fixturesURL))
        let movie = try Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("staff/ciel/ciel-idle-512.mov"))
        // The bundled QuickTime movie's mdat payload starts after ftyp/wide/mdat.
        guard movie.count >= 36 + fixtures.payloadLength,
              String(data: movie[32..<36], encoding: .ascii) == "mdat" else {
            throw NSError(domain: "Drive fixture source changed", code: 1)
        }
        let payload = movie.subdata(in: 36..<(36 + fixtures.payloadLength))
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard digest == fixtures.payloadSHA256 else { throw NSError(domain: "Drive fixture payload changed", code: 1) }
        return try Dictionary(uniqueKeysWithValues: fixtures.files.map { file in
            guard let header = Data(base64Encoded: file.header) else { throw NSError(domain: "Drive fixture header", code: 1) }
            return (file.durationSeconds, VirtualDriveMedia(header: header, payload: payload, repetitions: file.repetitions))
        })
    }

    func data(start: Int, length: Int) -> Data {
        var result = Data(capacity: length)
        var cursor = start
        let end = start + length
        if cursor < header.count {
            let limit = min(end, header.count)
            result.append(header.subdata(in: cursor..<limit)); cursor = limit
        }
        while cursor < end {
            let offset = (cursor - header.count) % payload.count
            let count = min(end - cursor, payload.count - offset)
            result.append(payload.subdata(in: offset..<(offset + count))); cursor += count
        }
        return result
    }
}

private final class DriveRangeServer {
    struct MediaRequest { let id: String; let start: Int; let length: Int }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "laa.drive.range.test")
    private let lock = NSLock()
    private var range = ""
    private var started = false
    private var closed = false
    private var authorized = false
    private var mediaRanges: [MediaRequest] = []
    private var pendingMedia: [ObjectIdentifier: MediaRequest] = [:]
    private var cancelledMedia: [ObjectIdentifier: MediaRequest] = [:]
    private var connections: [NWConnection] = []
    private let media: [String: VirtualDriveMedia]
    var lastRange: String { lock.withLock { range } }
    var sawTestAuthorization: Bool { lock.withLock { authorized } }
    func mediaRequests(_ id: String) -> [MediaRequest] { lock.withLock { mediaRanges.filter { $0.id == id } } }
    func pendingMediaIDs(_ id: String) -> Set<ObjectIdentifier> {
        lock.withLock { Set(pendingMedia.filter { $0.value.id == id }.map(\.key)) }
    }
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }

    private init(media: [String: VirtualDriveMedia]) throws {
        self.media = media
        listener = try NWListener(using: .tcp, on: .any)
    }
    static func start(media: [String: VirtualDriveMedia] = [:]) async throws -> DriveRangeServer {
        let server = try DriveRangeServer(media: media)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                if case .ready = state { server.listener.stateUpdateHandler = nil; continuation.resume() }
                else if case .failed(let error) = state { server.listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
            }
            server.listener.newConnectionHandler = { [weak server] connection in server?.accept(connection) }
            server.listener.start(queue: server.queue)
        }
        return server
    }
    func stop() { listener.cancel(); queue.sync { connections.forEach { $0.cancel() } } }
    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { return }
            let line = request.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }) ?? ""
            let authorization = request.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("authorization:") }) ?? ""
            self.lock.withLock {
                self.range = line.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
                self.authorized = authorization.lowercased() == "authorization: bearer test-token"
            }
            if let (id, media) = self.media.first(where: { request.contains("/\($0.key)/") }) {
                let bounds = line.split(separator: "=").last?.split(separator: "-") ?? []
                guard bounds.count == 2, let start = Int(bounds[0]), let requestedEnd = Int(bounds[1]),
                      start >= 0, start < media.size, requestedEnd >= start else { connection.cancel(); return }
                let end = min(requestedEnd, media.size - 1)
                let record = MediaRequest(id: id, start: start, length: end - start + 1)
                let key = ObjectIdentifier(connection)
                self.lock.withLock { self.mediaRanges.append(record); self.pendingMedia[key] = record }
                // Slower than an in-memory server, so the test can seek while
                // a transfer is outstanding and observe its cancellation.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
                    guard (complete || error != nil), let self else { return }
                    self.lock.withLock {
                        if let pending = self.pendingMedia.removeValue(forKey: key) { self.cancelledMedia[key] = pending }
                    }
                }
                self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                    let pending = self.lock.withLock { self.pendingMedia.removeValue(forKey: key) != nil }
                    guard pending else { return }
                    let header = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(end)/\(media.size)\r\nContent-Length: \(record.length)\r\nContent-Type: video/mp4\r\n\r\n"
                    self.send(header, body: media.data(start: start, length: record.length), on: connection)
                }
            } else if request.contains("/slow01/") {
                self.lock.withLock { self.started = true }
                self.send("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-999/1000\r\nContent-Length: 1000\r\nContent-Type: video/mp4\r\n\r\n", body: Data([1, 2, 3]), on: connection, closeWhenDone: false)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
                    if (complete || error != nil), let self { self.lock.withLock { self.closed = true } }
                }
            } else if request.contains("/outside01/") {
                self.send("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */1000\r\nContent-Length: 0\r\n\r\n", body: Data(), on: connection)
            } else if request.contains("/ignore01/") {
                self.send("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n", body: Data(repeating: 0, count: 1000), on: connection)
            } else {
                let body = Data((500..<600).map { UInt8($0 % 251) })
                self.send("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 500-599/1000\r\nContent-Length: 100\r\nContent-Type: video/mp4\r\n\r\n", body: body, on: connection)
            }
        }
    }
    private func send(_ header: String, body: Data, on connection: NWConnection, closeWhenDone: Bool = true) {
        let header = closeWhenDone ? header.replacingOccurrences(of: "\r\n\r\n", with: "\r\nConnection: close\r\n\r\n") : header
        var data = Data(header.utf8); data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            if closeWhenDone { connection.cancel() }
        })
    }
    func waitForSlowRequest() async throws { try await wait { self.started } }
    func waitForClose() async throws { try await wait { self.closed } }
    func waitForPendingMedia(_ id: String) async throws {
        try await wait { self.pendingMedia.values.contains { $0.id == id } }
    }
    func waitForCancelledMedia(_ id: String, among candidates: Set<ObjectIdentifier>) async throws {
        try await wait { candidates.contains { self.cancelledMedia[$0]?.id == id } }
    }
    func waitForMiddleMediaRequest(_ id: String, after count: Int, total: Int) async throws {
        try await wait {
            self.mediaRanges.filter { $0.id == id }.dropFirst(count)
                .contains { $0.start > total * 35 / 100 && $0.start < total * 65 / 100 }
        }
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            let done = lock.withLock { condition() }
            if done { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "DriveRangeServer timeout", code: 1)
    }
}
#endif
