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
    var version: String? = nil
    var size: Int64? = nil
}

enum LAABridgeError: Error {
    case invalidResponse
    var japaneseText: String { "Invalid response" }
}
enum LAADriveRangeError: Error { case invalidRange, versionChanged }
enum LAADrivePresentation {
    static func message(_ error: Error) -> String { String(describing: error) }
}
enum LAACopy {
    enum Drive { static let invalidPreview = "Invalid preview" }
}
enum LAADrivePaths {
    static func content(_ id: String) throws -> String { "/v1/drive/files/\(id)/content" }
    static func validVersion(_ value: String) -> Bool { !value.isEmpty && value.allSatisfy(\.isNumber) }
}
enum LAAStudioMedia { static func bridgePathIsValid(_ path: String) -> Bool { false } }
struct RangeResult {
    let data: Data
    let total: Int64
    let mimeType: String?
    let version: String?
}
typealias LAADriveRangeResponse = RangeResult

private struct TransferMeasurement {
    let result: RangeResult
    let timings: [String: Double]
}

// The iOS session is MainActor-isolated, but its LAABridgeClient.driveRange
// implementation is a nonisolated async method. Run the modeled transport on
// the generic executor too, so per-byte processing does not occupy the UI actor.
private func measuredTransfer(_ request: URLRequest, offset: Int64, length: Int) async throws -> TransferMeasurement {
    let started = Date()
    // Simulated iPhone-to-Bridge RTT, before the request goes to loopback.
    let rttMs = Int(ProcessInfo.processInfo.environment["LAA_BENCH_RTT_MS"] ?? "50") ?? 50
    try await Task.sleep(for: .milliseconds(rttMs))
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
    return .init(result: .init(data: data, total: total, mimeType: http.mimeType,
                               version: http.value(forHTTPHeaderField: "x-laa-drive-version")),
                 timings: ["size": Double(data.count),
                           "headersMs": headersAt.timeIntervalSince(started) * 1_000,
                           "bodyMs": Date().timeIntervalSince(headersAt) * 1_000])
}

@MainActor final class LAABridgeSession {
    let baseURL: URL
    let token: String
    init(baseURL: URL, token: String) { self.baseURL = baseURL; self.token = token }
    func driveRange(path: String, offset: Int64, length: Int) async throws -> RangeResult {
        throw LAABridgeError.invalidResponse // Studio playback is not part of this measurement.
    }
}

enum LAADriveContent {
    // The default matches the iOS source; larger values are experiments only.
    static let chunkSize = Int(ProcessInfo.processInfo.environment["LAA_BENCH_CHUNK_BYTES"] ?? "524288") ?? 524288
    @MainActor static var requests = 0
    @MainActor static var completedRanges: [[String: Double]] = []
    @MainActor static func range(_ item: LAADriveItem, offset: Int64, length: Int,
                                 bridge: LAABridgeSession, expectedVersion: String? = nil) async throws -> RangeResult {
        requests += 1
        var request = URLRequest(url: bridge.baseURL.appendingPathComponent("v1/drive/files/\(item.id)/content"))
        request.setValue("Bearer \(bridge.token)", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        if let expectedVersion { request.setValue(expectedVersion, forHTTPHeaderField: "x-laa-drive-version") }
        let measurement = try await measuredTransfer(request, offset: offset, length: length)
        if let expectedVersion, measurement.result.version != expectedVersion { throw LAADriveRangeError.versionChanged }
        completedRanges.append(measurement.timings)
        return measurement.result
    }
}

@main struct Benchmark {
    @MainActor static func waitForFrame(_ output: AVPlayerItemVideoOutput, player: AVPlayer,
                                        atLeast minimum: Double, timeout: Double = 40) async throws -> Double {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            let time = player.currentTime()
            if player.timeControlStatus == .playing, time.seconds.isFinite, time.seconds >= minimum,
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
        struct Input: Decodable { let base: URL; let token: String; let id: String; let mimeType: String; let version: String?; let size: Int64? }
        let input = try? JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
        guard let base = input?.base ?? env["LAA_BENCH_BASE"].flatMap(URL.init(string:)),
              let token = input?.token ?? env["LAA_BENCH_FAKE_TOKEN"] else { throw LAABridgeError.invalidResponse }
        let repetitions = Int(env["LAA_BENCH_REPETITIONS"] ?? "10") ?? 10
        let bridge = LAABridgeSession(baseURL: base, token: token)
        for index in 0..<repetitions {
            let player = LAADrivePlayer(item: .init(id: input?.id ?? "fixture_video_\(index)", mimeType: input?.mimeType ?? "video/mp4", version: input?.version, size: input?.size), bridge: bridge)
            player.player.isMuted = true
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            guard let item = player.player.currentItem else { throw LAABridgeError.invalidResponse }
            item.add(output)
            let before = LAADriveContent.requests
            let beforeRanges = LAADriveContent.completedRanges.count
            let coordinator = LAADrivePlaybackCoordinator(player: player.player, identity: nil,
                startsBufferedPlayback: env["LAA_BENCH_START_BUFFERED"] == "1",
                openSource: { player.open() }, closeSource: { player.close() },
                acquireAudio: {}, releaseAudio: {})
            coordinator.start(autoPlay: true)
            let startup = try await waitForFrame(output, player: player.player, atLeast: 0)
            let afterStartup = LAADriveContent.requests
            let duration = item.duration.seconds
            let seekSeconds = min(Double(env["LAA_BENCH_SEEK_SECONDS"] ?? "4") ?? 4, max(0.5, duration * 0.7))
            let startSeek = Date()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                player.player.seek(to: CMTime(seconds: seekSeconds, preferredTimescale: 600),
                                   toleranceBefore: .zero, toleranceAfter: .zero) { _ in continuation.resume() }
            }
            _ = try await waitForFrame(output, player: player.player, atLeast: seekSeconds - 0.05)
            let seek = Date().timeIntervalSince(startSeek) * 1_000
            let afterSeek = LAADriveContent.requests
            var stalls = 0
            var wasWaiting = false
            let monitoringStart = Date()
            let monitoringSeconds = min(120, max(1, Double(env["LAA_BENCH_OBSERVE_SECONDS"] ?? "1") ?? 1))
            while Date().timeIntervalSince(monitoringStart) < monitoringSeconds {
                if player.player.currentTime().seconds >= duration - 0.1 { break }
                let waiting = player.player.timeControlStatus != .playing && player.player.currentTime().seconds < duration - 0.1
                if waiting && !wasWaiting { stalls += 1 }
                wasWaiting = waiting
                try await Task.sleep(for: .milliseconds(20))
            }
            let tracks = try await item.asset.loadTracks(withMediaType: .video)
            let descriptions = try await tracks.first?.load(.formatDescriptions)
            let subtype = descriptions?.first.map(CMFormatDescriptionGetMediaSubType) ?? 0
            let codec = String(bytes: [24,16,8,0].map { UInt8((subtype >> $0) & 255) }, encoding: .ascii) ?? "unknown"
            var result: [String: Any] = ["trial": index + 1, "startupMs": startup, "seekMs": seek, "duration": duration, "codec": codec, "stallsAfterSeek": stalls, "stallObservationSeconds": Date().timeIntervalSince(monitoringStart), "advancedAfterSeekSeconds": player.player.currentTime().seconds - seekSeconds,
                                         "startupRequests": afterStartup - before,
                                         "seekRequests": afterSeek - afterStartup,
                                         "completedRanges": Array(LAADriveContent.completedRanges.dropFirst(beforeRanges))]
            if monitoringSeconds == 1 { result["stallsDuringOneSecondAfterSeek"] = stalls }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
            coordinator.stop()
        }
    }
}
