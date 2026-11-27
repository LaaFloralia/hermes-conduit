#if LAA_BUILD
import CryptoKit
import Foundation
import os

@propertyWrapper struct NullMetric<Value: Codable & Sendable>: Codable, Sendable {
    var wrappedValue: Value? = nil
    init(wrappedValue: Value? = nil) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = try decoder.singleValueContainer().decode(Value?.self) }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(wrappedValue)
    }
}

struct TurnMetrics: Codable, Sendable {
    struct Client: Codable, Sendable {
        /// Unix milliseconds derived from one wall/monotonic clock anchor.
        let t_submit: Int64
        @NullMetric var t_accepted_ms: Int64?
        @NullMetric var t_first_event_ms: Int64?
        @NullMetric var t_first_text_ms: Int64?
        @NullMetric var t_first_visible_ms: Int64?
        @NullMetric var t_complete_ms: Int64?
        @NullMetric var t_settled_ms: Int64?
    }

    struct Runtime: Codable, Sendable {
        @NullMetric var steps: Int?
        @NullMetric var tool_calls: Int?
        @NullMetric var temperature: String?
        @NullMetric var asked_again: Int?
        @NullMetric var compactions: Int?
        @NullMetric var prompt_tokens: Int?
        @NullMetric var cached_tokens: Int?
        @NullMetric var output_tokens: Int?
        @NullMetric var thought_tokens: Int?
        @NullMetric var context_tokens: Int?
        @NullMetric var context_window: Int?

        mutating func observe(_ fields: [String: AnyCodable]) {
            // Plain prompt/input/calls/output/reasoning are session-cumulative
            // in Hermes. Never present one of those as a per-turn count.
            let turn = fields["turn"]?.objectValue ?? [:]
            func reading(_ key: String) -> Int? {
                (turn[key]?.intValue ?? fields["turn_" + key]?.intValue).flatMap { $0 >= 0 ? $0 : nil }
            }
            steps = reading("steps") ?? steps
            tool_calls = reading("tool_calls") ?? tool_calls
            if let tag = (turn["temperature"] ?? fields["turn_temperature"])?.stringValue, ["cold", "warm"].contains(tag) {
                temperature = tag
            }
            asked_again = reading("asked_again") ?? asked_again
            compactions = reading("compactions") ?? compactions
            prompt_tokens = reading("prompt_tokens") ?? reading("input_tokens") ?? prompt_tokens
            cached_tokens = reading("cached_tokens") ?? cached_tokens
            output_tokens = reading("output_tokens") ?? output_tokens
            thought_tokens = reading("thought_tokens") ?? thought_tokens
            context_tokens = fields["context_used"]?.intValue ?? context_tokens
            context_window = fields["context_max"]?.intValue ?? context_window
        }
    }

    let turn_id: UUID
    let conversation_id: String
    let profile: String
    @NullMetric var model: String?
    @NullMetric var effort: String?
    var client: Client
    var runtime = Runtime()

    init(turn_id: UUID, conversation_id: String, profile: String, model: String?, effort: String?, client: Client) {
        self.turn_id = turn_id
        self.conversation_id = conversation_id
        self.profile = profile
        self.model = model
        self.effort = effort
        self.client = client
    }

    static func opaque(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func profileLabel(_ value: String) -> String {
        let known = ["default", "laa-monet", "laa-lavandula", "laa-vanda", "laa-camellia", "laa-lunaria", "laa-freesia", "laa-astrantia"]
        return known.contains(value) ? value : opaque(value)
    }
}

/// Disk and uploads are off the event path. Reuse the paired-device diagnostics
/// route with a content-addressed batch, not one Bridge request per turn.
actor ChatTurnMetricsStore {
    static let shared = ChatTurnMetricsStore()
    static let filename = "chat-turn-metrics.jsonl"
    private static let log = Logger(subsystem: "com.laa.hortensia", category: "ChatTurnMetrics")
    private static let maxBytes = 512 * 1024
    private var lastAttempt: TimeInterval?
    private let directory: URL?
    private let upload: Bool

    init(directory: URL? = nil, upload: Bool = false) {
        self.directory = directory
        self.upload = upload
    }

    private init() { directory = nil; upload = true }

    private var folder: URL? {
        directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("LAA", isDirectory: true) }
    }

    func append(_ metrics: TurnMetrics) async {
        guard let folder else { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent(Self.filename)
            let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var line = try encoder.encode(metrics)
            line.append(0x0A)
            let rotated = size + line.count > Self.maxBytes
            if rotated {
                let previous = folder.appendingPathComponent(Self.filename + ".1")
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                try manager.moveItem(at: file, to: previous)
            }
            if !manager.fileExists(atPath: file.path) {
                guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: line)
            let now = ProcessInfo.processInfo.systemUptime
            guard upload, lastAttempt.map({ 6 * 3600 <= now - $0 }) ?? true else { return }
#if DEBUG
            guard !LAALabNetworkPolicy.current.isActive,
                  ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
#endif
            let previous = folder.appendingPathComponent(Self.filename + ".1")
            let lines = [previous, file].compactMap { try? Data(contentsOf: $0) }
                .flatMap { $0.split(separator: 0x0A) }
            let rows = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) }
            guard let body = try? JSONSerialization.data(withJSONObject: ["schema": 1, "turns": rows], options: [.sortedKeys]) else { return }
            lastAttempt = now
            if !(await LAADeviceReportUpload.send(name: "metrics-chat-turn-v1.json", json: body)) {
                // Subsequent turns may retry after a short cooldown, leaving
                // the bounded local journal readable even when unpaired.
                lastAttempt = now - 6 * 3600 + 60
            }
        } catch { Self.log.error("Could not append Chat turn metrics") }
    }
}
#endif
