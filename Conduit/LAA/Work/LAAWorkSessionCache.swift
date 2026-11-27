#if LAA_BUILD
import Foundation
import Combine
import CryptoKit

/// Snapshots of what Work last read (session lists, a session's detail and
/// history, decisions, project snapshots, skills), shown before the network
/// answers. They never authorize a mutation: decisions are fetched again
/// before an answer is sent.
@MainActor enum LAAWorkSessionCache {
    static let shared = LAAWorkSessionCacheStore(directory: LAAWorkSessionCacheStore.defaultDirectory)
    static func read<T: Decodable>(_ type: T.Type, store: ComposerDraftStore, device: String?, target: String) -> T? {
        shared.read(type, store: store, device: device, target: target)
    }
    static func save<T: Encodable>(_ value: T, store: ComposerDraftStore, device: String?, target: String) {
        shared.save(value, store: store, device: device, target: target)
    }
}

/// One protected file per (device, target), written off the main thread.
/// Until D-16 every snapshot was a draft in the Work draft store, so any changed
/// poll (and every keystroke beside it) rewrote that whole multi-MB file on the
/// main actor, and snapshots competed with the owner's drafts for its slots.
@MainActor final class LAAWorkSessionCacheStore {
    static let legacyProfile = "laa-session-cache-v1"
    /// Files not written for this long belong to sessions no longer opened.
    static let retention: TimeInterval = 14 * 24 * 60 * 60

    nonisolated static var defaultDirectory: URL {
        LAAWorkDrafts.fileURL.deletingLastPathComponent().appendingPathComponent("session-cache-v2", isDirectory: true)
    }

    let directory: URL
    private let writer: Writer
    /// The last bytes per file name: unchanged saves skip disk, and a read
    /// right after a save sees it before the write lands.
    private var memory: [String: Data] = [:]
    private var started = false
    private let cleanedStores = NSHashTable<ComposerDraftStore>.weakObjects()

    init(directory: URL, queue: DispatchQueue = DispatchQueue(label: "laa.work.session-cache", qos: .utility),
         write: @escaping @Sendable (Data, URL) throws -> Void = { try LAAWorkSessionCacheStore.writeFile($0, to: $1) }) {
        self.directory = directory
        writer = Writer(directory: directory, queue: queue, write: write)
        #if DEBUG
        // UI tests start with no remembered Work state (`LAAWorkDrafts.makeStore`).
        if directory == Self.defaultDirectory,
           ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_CLEAR_WORK_STORE") {
            try? FileManager.default.removeItem(at: directory)
        }
        #endif
    }

    func fileURL(device: String, target: String) -> URL {
        directory.appendingPathComponent(Self.fileName(device: device, target: target))
    }

    func read<T: Decodable>(_ type: T.Type, store: ComposerDraftStore?, device: String?, target: String) -> T? {
        prepare(store)
        guard let device else { return nil }
        let name = Self.fileName(device: device, target: target)
        let data: Data
        if let held = memory[name] {
            data = held
        } else {
            guard let stored = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            memory[name] = stored
            data = stored
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T, store: ComposerDraftStore?, device: String?, target: String) {
        prepare(store)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let device, let data = try? encoder.encode(value) else { return }
        let name = Self.fileName(device: device, target: target)
        // Long polls often return the same history; that costs no I/O.
        guard memory[name] != data || writer.failed(name) else { return }
        memory[name] = data
        writer.enqueue(data, name: name)
    }

    /// Waits until every queued write and the eviction have finished (tests).
    func flush() { writer.flush() }

    nonisolated static func writeFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    nonisolated static func fileName(device: String, target: String) -> String {
        SHA256.hash(data: Data("\(device):\(target)".utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func prepare(_ store: ComposerDraftStore?) {
        if !started {
            started = true
            writer.evictStale(olderThan: Self.retention)
        }
        // Snapshots written by earlier builds are a cache: drop them from the
        // draft store in one write, without moving them; the next fetch refills.
        // A store that could not be read (or write) is left for a later use.
        guard let store, !cleanedStores.contains(store), !store.persistenceFailed else { return }
        if store.removeDrafts(where: { $0.profile == Self.legacyProfile }) { cleanedStores.add(store) }
    }

    /// Serial, coalescing file writes. A key's queued write always takes its
    /// latest bytes, and a later save queues behind any write in progress.
    private final class Writer: @unchecked Sendable {
        private let directory: URL
        private let queue: DispatchQueue
        private let write: @Sendable (Data, URL) throws -> Void
        private let lock = NSLock()
        private var pending: [String: Data] = [:]
        private var failures: Set<String> = []
        private var directoryReady = false

        init(directory: URL, queue: DispatchQueue, write: @escaping @Sendable (Data, URL) throws -> Void) {
            self.directory = directory
            self.queue = queue
            self.write = write
        }

        func failed(_ name: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return failures.contains(name)
        }

        func enqueue(_ data: Data, name: String) {
            lock.lock()
            let scheduled = pending[name] != nil
            pending[name] = data
            lock.unlock()
            guard !scheduled else { return }
            queue.async { [self] in
                lock.lock()
                let latest = pending.removeValue(forKey: name)
                lock.unlock()
                guard let latest else { return }
                let succeeded: Bool
                do {
                    try prepareDirectory()
                    try write(latest, directory.appendingPathComponent(name))
                    succeeded = true
                } catch {
                    succeeded = false
                }
                lock.lock()
                if succeeded { failures.remove(name) } else { failures.insert(name) }
                lock.unlock()
            }
        }

        func evictStale(olderThan age: TimeInterval) {
            queue.async { [directory] in
                let cutoff = Date().addingTimeInterval(-age)
                let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
                guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
                for file in files {
                    guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                          let modified = values.contentModificationDate, modified < cutoff else { continue }
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }

        func flush() { queue.sync {} }

        /// Runs on `queue` only.
        private func prepareDirectory() throws {
            guard !directoryReady else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            directoryReady = true
        }
    }
}

@MainActor final class LAAWorkLinkRequest: ObservableObject {
    static let shared = LAAWorkLinkRequest()
    @Published var url: URL?
    @Published private(set) var generation: UInt64 = 0
    @discardableResult func open(_ url: URL) -> Bool {
        guard url.scheme == "laa", ["work", "today", "brain", "assets"].contains(url.host ?? "") else { return false }
        self.url = url
        generation &+= 1
        return true
    }
    /// Generations each view has already acted on. The link stays readable,
    /// but a view built again later (opening Work, switching back to it) must
    /// not replay an old notification's link: an answered decision reopened
    /// the board every time Work was opened (2026-11-26).
    private var handled: [String: UInt64] = [:]
    /// The pending link for `consumer`, once per `open`.
    func claim(_ consumer: String) -> URL? {
        guard generation != 0, handled[consumer] != generation, let url else { return nil }
        handled[consumer] = generation
        return url
    }
    var calendarEvent: (id: String, calendarID: String)? {
        guard url?.host == "today", let url, url.pathComponents.count == 3, url.pathComponents[1] == "events",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let calendar = components.queryItems?.first(where: { $0.name == "calendar" })?.value, !calendar.isEmpty else { return nil }
        let id = url.pathComponents[2]
        return id.isEmpty ? nil : (id, calendar)
    }
    var sessionTarget: String? {
        guard url?.host == "work", let parts = url?.pathComponents, parts.count == 3, parts[1] == "sessions" else { return nil }
        let id = parts[2]
        guard id.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil else { return nil }
        return id
    }
    var projectTarget: String? {
        guard url?.host == "work", let parts = url?.pathComponents, parts.count == 3,
              parts[1] == "projects", parts[2].range(of: "^prj_[0-9a-f]{12}$", options: .regularExpression) != nil else { return nil }
        return parts[2]
    }
    /// `laa://work/decisions` (the board) or `laa://work/decisions/<id>`.
    var decisionsLink: Bool { url?.host == "work" && url?.pathComponents.dropFirst().first == "decisions" }
    var decisionTarget: String? {
        guard decisionsLink, let parts = url?.pathComponents, parts.count == 3,
              parts[2].range(of: "^dec_[0-9a-f]{16}$|^ses_[0-9a-f]{16}$", options: .regularExpression) != nil else { return nil }
        return parts[2]
    }
    var sessionID: String? {
        guard let id = sessionTarget, id.range(of: "^ses_[0-9a-f]{16}$", options: .regularExpression) != nil else { return nil }
        return id
    }
}
#endif
