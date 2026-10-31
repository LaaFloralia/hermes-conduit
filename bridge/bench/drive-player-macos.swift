// Test harness only. The benchmark appends the unmodified LAADrivePlayer class
// from the iOS source to this file before compiling it for macOS. The small
// Bridge session below models the iOS Range transport and an extra 50 ms RTT;
// this is not an iPhone measurement.
import Foundation
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import CoreVideo

struct LAADriveItem {
    let id: String
    let mimeType: String
}

enum LAABridgeError: Error {
    case invalidResponse
    var japaneseText: String { "Invalid response" }
}
enum LAADriveRangeError: Error { case invalidRange }
enum LAADrivePresentation {
    static func message(_ error: Error) -> String { String(describing: error) }
}
enum LAACopy {
    enum Drive { static let invalidPreview = "Invalid preview" }
}
enum LAADrivePaths {
    static func content(_ id: String) throws -> String { "/v1/drive/files/\(id)/content" }
}
struct RangeResult {
    let data: Data
    let total: Int64
    let mimeType: String?
}
@MainActor final class LAABridgeSession {
    let baseURL: URL
    let token: String
    init(baseURL: URL, token: String) { self.baseURL = baseURL; self.token = token }
}

enum LAADriveContent {
    // The default matches the iOS source; larger values are experiments only.
    static let chunkSize = Int(ProcessInfo.processInfo.environment["LAA_BENCH_CHUNK_BYTES"] ?? "262144") ?? 262144
    @MainActor static var requests = 0
    @MainActor static var completedRanges: [[String: Double]] = []
    @MainActor static func range(_ item: LAADriveItem, offset: Int64, length: Int,
                                 bridge: LAABridgeSession) async throws -> RangeResult {
        requests += 1
        let started = Date()
        // Simulated iPhone-to-Bridge RTT, before the request goes to loopback.
        try await Task.sleep(for: .milliseconds(50))
        var request = URLRequest(url: bridge.baseURL.appendingPathComponent("v1/drive/files/\(item.id)/content"))
        request.setValue("Bearer \(bridge.token)", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        if ProcessInfo.processInfo.environment["LAA_BENCH_TRANSPORT"] == "blocks" {
            let response = try await LAADriveRangeTransfer.shared.read(request, offset: offset, length: length)
            guard response.response.statusCode == 206, let total = response.total else {
                throw LAADriveRangeError.invalidRange
            }
            completedRanges.append(["size": Double(response.data.count),
                                    "totalMs": Date().timeIntervalSince(started) * 1_000])
            return .init(data: response.data, total: total, mimeType: response.response.mimeType)
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let headersAt = Date()
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let header = http.value(forHTTPHeaderField: "Content-Range"),
              header.hasPrefix("bytes ") else { throw LAADriveRangeError.invalidRange }
        let halves = header.dropFirst(6).split(separator: "/")
        guard halves.count == 2, let total = Int64(halves[1]) else { throw LAADriveRangeError.invalidRange }
        let bounds = halves[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start == offset, end >= start, end < total, end < offset + Int64(length) else {
            throw LAADriveRangeError.invalidRange
        }
        let expected = Int(end - start + 1)
        var data = Data(capacity: expected)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < expected else { throw LAADriveRangeError.invalidRange }
            data.append(byte)
        }
        guard data.count == expected else { throw LAADriveRangeError.invalidRange }
        completedRanges.append(["size": Double(data.count),
                                "headersMs": headersAt.timeIntervalSince(started) * 1_000,
                                "bodyMs": Date().timeIntervalSince(headersAt) * 1_000])
        return .init(data: data, total: total, mimeType: http.mimeType)
    }
}

@main struct Benchmark {
    @MainActor static func waitForFrame(_ output: AVPlayerItemVideoOutput, player: AVPlayer,
                                        atLeast minimum: Double, timeout: Double = 12) async throws -> Double {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            let time = player.currentTime()
            if time.seconds.isFinite, time.seconds >= minimum,
               output.hasNewPixelBuffer(forItemTime: time) {
                var displayTime = CMTime.invalid
                if output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime) != nil,
                   displayTime.seconds.isFinite, displayTime.seconds >= minimum {
                    return Date().timeIntervalSince(started) * 1_000
                }
            }
            if player.currentItem?.status == .failed {
                throw player.currentItem?.error ?? LAABridgeError.invalidResponse
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "DriveBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "frame timed out"])
    }

    @MainActor static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["LAA_BENCH_BASE"].flatMap(URL.init(string:)),
              let token = env["LAA_BENCH_FAKE_TOKEN"] else { throw LAABridgeError.invalidResponse }
        let repetitions = Int(env["LAA_BENCH_REPETITIONS"] ?? "10") ?? 10
        let bridge = LAABridgeSession(baseURL: base, token: token)
        for index in 0..<repetitions {
            let player = LAADrivePlayer(item: .init(id: "fixture_video_\(index)", mimeType: "video/mp4"), bridge: bridge)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            guard let item = player.player.currentItem else { throw LAABridgeError.invalidResponse }
            item.add(output)
            let before = LAADriveContent.requests
            let beforeRanges = LAADriveContent.completedRanges.count
            player.player.play()
            let startup = try await waitForFrame(output, player: player.player, atLeast: 0)
            let afterStartup = LAADriveContent.requests
            let startSeek = Date()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                player.player.seek(to: CMTime(seconds: 4, preferredTimescale: 600),
                                   toleranceBefore: .zero, toleranceAfter: .zero) { _ in continuation.resume() }
            }
            _ = try await waitForFrame(output, player: player.player, atLeast: 3.95)
            let seek = Date().timeIntervalSince(startSeek) * 1_000
            let afterSeek = LAADriveContent.requests
            let result: [String: Any] = ["trial": index + 1, "startupMs": startup, "seekMs": seek,
                                         "startupRequests": afterStartup - before,
                                         "seekRequests": afterSeek - afterStartup,
                                         "completedRanges": Array(LAADriveContent.completedRanges.dropFirst(beforeRanges))]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
            player.close()
        }
    }
}
