import Foundation

struct WidgetSnapshotStore {
    /// The App Group this build shares with the app and the widgets: the one
    /// the build names in its Info.plist (`ConduitLauncherAppGroup`, from
    /// `CONDUIT_LAUNCHER_APP_GROUP`), else upstream's. Every target that reads
    /// the snapshot passes the same key through its own Info.plist, so a build
    /// under another team's App Groups needs no source edit.
    static let appGroup = configuredAppGroup("ConduitLauncherAppGroup")
        ?? "group.com.milim.relay.launcher"

    /// The App Group a build names in its Info.plist, when it names a usable
    /// one. Anything else (absent, empty, an unexpanded build setting) leaves
    /// the caller its upstream group.
    static func configuredAppGroup(_ key: String) -> String? {
        guard let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("group.") else { return nil }
        return value
    }

    static let filename = "launcher-v1.json"
    private let directory: URL
    private let fileManager: FileManager
    private let writeObserver: (() -> Void)?

    init(directory: URL, fileManager: FileManager = .default, writeObserver: (() -> Void)? = nil) {
        self.directory = directory
        self.fileManager = fileManager
        self.writeObserver = writeObserver
    }

    static var production: WidgetSnapshotStore? {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        return WidgetSnapshotStore(directory: directory)
    }

    func read() -> WidgetSnapshot? {
        let url = directory.appendingPathComponent(Self.filename)
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              value.schemaVersion == WidgetSnapshot.currentSchemaVersion else { return nil }
        return value
    }

    @discardableResult
    func write(_ snapshot: WidgetSnapshot) throws -> Bool {
        #if LAA_BUILD
        // Chat catalogue publications predate usage and must not erase it.
        let snapshot = snapshot.usage == nil ? snapshot.withUsage(read()?.usage) : snapshot
        #endif
        return try writeRaw(snapshot)
    }

    #if LAA_BUILD
    @discardableResult
    func writeUsage(_ usage: WidgetUsageSnapshot?) throws -> Bool {
        let snapshot = read() ?? WidgetSnapshot(appLanguage: "ja", currentWorkspaceID: nil, workspaces: [])
        return try writeRaw(snapshot.withUsage(usage))
    }
    #endif

    private func writeRaw(_ snapshot: WidgetSnapshot) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let url = directory.appendingPathComponent(Self.filename)
        if let previous = try? Data(contentsOf: url), previous == data { return false }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        writeObserver?()
        return true
    }
}
