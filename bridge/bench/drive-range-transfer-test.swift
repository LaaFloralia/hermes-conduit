// macOS CLI contract tests for the same bounded transport compiled into LAA.
import Foundation

struct TestFailure: Error { let message: String }

@main struct RangeTransferTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message: message) }
    }

    static func expect(_ expected: LAADriveTransferError, _ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            throw TestFailure(message: "expected \(expected)")
        } catch let error as LAADriveTransferError {
            try require(error == expected, "unexpected transfer error: \(error)")
        }
    }

    static func main() async throws {
        guard let base = ProcessInfo.processInfo.environment["LAA_BENCH_BASE"].flatMap(URL.init(string:)) else {
            throw TestFailure(message: "missing local fixture address")
        }
        func request(_ path: String) -> URLRequest {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.setValue("Bearer synthetic-fixture", forHTTPHeaderField: "Authorization")
            return request
        }
        let transfer = LAADriveRangeTransfer.shared
        let normal = try await transfer.read(request("valid"), offset: 10, length: 5)
        try require(normal.response.statusCode == 206 && normal.total == 2048, "valid response metadata")
        try require(normal.data == Data([10, 11, 12, 13, 14]), "valid response bytes")

        try await expect(.rangeUnsupported) { _ = try await transfer.read(request("ignored"), offset: 10, length: 5) }
        try await expect(.unsatisfiable) { _ = try await transfer.read(request("unsatisfiable"), offset: 10, length: 5) }
        try await expect(.invalidRange) { _ = try await transfer.read(request("bad-range"), offset: 10, length: 5) }
        try await expect(.invalidRange) { _ = try await transfer.read(request("bad-length"), offset: 10, length: 5) }
        try await expect(.invalidRange) { _ = try await transfer.read(request("overrun"), offset: 10, length: 5) }
        try await expect(.invalidRange) { _ = try await transfer.read(request("short"), offset: 10, length: 5) }
        try await expect(.invalidRange) { _ = try await transfer.read(request("valid"), offset: 0, length: 2_097_153) }
        try await expect(.invalidRange) { _ = try await transfer.read(request("valid"), offset: .max, length: 2) }

        let redirected = try await transfer.read(request("redirect"), offset: 0, length: 5)
        try require(redirected.response.statusCode == 302, "redirect must not be followed")
        let error = try await transfer.read(request("error"), offset: 0, length: 5)
        try require(error.response.statusCode == 503 && error.data.count == 8192, "error body must be bounded")

        let cancelledBeforeStart = Task { try await transfer.read(request("slow"), offset: 0, length: 2048) }
        cancelledBeforeStart.cancel()
        do {
            _ = try await cancelledBeforeStart.value
            throw TestFailure(message: "request cancelled before start succeeded")
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        }

        let cancelled = Task { try await transfer.read(request("slow"), offset: 0, length: 2048) }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw TestFailure(message: "cancelled request succeeded")
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for offset in 0..<20 {
                group.addTask {
                    let response = try await transfer.read(request("parallel"), offset: Int64(offset), length: 7)
                    let expected = Data((offset..<(offset + 7)).map { UInt8($0 % 251) })
                    try require(response.total == 2048 && response.data == expected, "concurrent ranges crossed")
                }
            }
            try await group.waitForAll()
        }
        print("bounded Drive range transport: valid, malformed, overflow, cancellation, redirect and 20 concurrent requests passed")
    }
}
