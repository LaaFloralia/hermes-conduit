#if LAA_BUILD
import AppIntents
import Combine
import Foundation

/// Persist a launch until the selected vault is available, including on a
/// cold launch or when the user first has to choose the folder.
@MainActor final class LAABrainDailyRequest: ObservableObject {
    static let shared = LAABrainDailyRequest()
    private static let key = "laa.brain.daily.request"
    private let defaults: UserDefaults
    @Published private(set) var id: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        id = defaults.string(forKey: Self.key)
    }

    func enqueue() {
        let next = UUID().uuidString
        defaults.set(next, forKey: Self.key)
        id = next
    }

    func consume(_ expected: String) {
        guard id == expected else { return }
        defaults.removeObject(forKey: Self.key)
        id = nil
    }
}

enum LAABrainDailyNote {
    static let folder = "daily journal"

    /// The owner's iPhone selects "このiPhone内/LAA", which holds Brain and HQ,
    /// so the vault is its Brain folder. A device that selected the Brain
    /// folder itself has no Brain child and the selected folder is the vault.
    /// A linked Brain is refused instead of writing a second `daily journal`
    /// at the selected folder's root.
    static func vault(root: URL) throws -> String {
        let brain = root.appendingPathComponent("Brain", isDirectory: true)
        guard let values = try? brain.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return ""
        }
        if values.isSymbolicLink == true { throw LAABrainVaultError.invalidPath }
        return values.isDirectory == true ? "Brain" : ""
    }

    static func path(root: URL, date: Date = Date(), timeZone: TimeZone = .current) throws -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.dateComponents([.year, .month, .day], from: date)
        let vault = try vault(root: root)
        let month = String(format: "%04d-%02d", date.year!, date.month!)
        return String(format: "%@%@/%@/%04d-%02d-%02d.md",
                      vault.isEmpty ? "" : vault + "/", folder, month, date.year!, date.month!, date.day!)
    }

    /// Exclusive creation keeps any file created by Syncthing or another
    /// writer, even if it appears between the existence check and creation.
    static func open(root: URL, date: Date = Date(), timeZone: TimeZone = .current,
                     journal: LAABrainSaveJournal = LAABrainSaveJournal()) throws -> String {
        let path = try path(root: root, date: date, timeZone: timeZone)
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { throw LAABrainFolderStore.Failure.invalidName }
        var parent = ""
        for part in parts.dropLast() {
            do { _ = try LAABrainFolderStore.create(root: root, parent: parent, name: part, kind: .folder) }
            catch LAABrainFolderStore.Failure.exists { }
            parent = parent.isEmpty ? part : parent + "/" + part
        }
        do { _ = try LAABrainFolderStore.create(root: root, parent: parent, name: name, kind: .note, journal: journal) }
        catch LAABrainFolderStore.Failure.exists { }
        // Validate that an existing item is a readable, non-symlink Markdown
        // note before navigating to it. Do not replace an invalid item.
        _ = try LAABrainVaultIO.note(root: root, path: path)
        return path
    }
}

struct OpenTodayDailyNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "今日のデイリーノートを開く"
    static let description = IntentDescription("Brainの今日のノートを開いて編集します。")

    @available(iOS, deprecated: 26.0, message: "Use supportedModes on iOS 26+; retained for iOS 17–25.")
    static let openAppWhenRun: Bool = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    func perform() async throws -> some IntentResult {
        await MainActor.run { LAABrainDailyRequest.shared.enqueue() }
        return .result()
    }
}
#endif
