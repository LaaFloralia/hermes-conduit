#if LAA_BUILD && DEBUG
import Foundation
import Darwin

@main struct BrainSaveFixtureCLI {
    typealias FixtureFailure = BrainSaveFixture.FixtureFailure
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { try BrainSaveFixture.check(condition(), message) }
    static func tryData(_ url: URL) -> Data? { BrainSaveFixture.tryData(url) }
    static func selftest(_ root: URL) throws { try BrainSaveFixture.selftest(root) }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw FixtureFailure() }
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        if args[1] == "selftest" { try selftest(root); return }
        if args[1] == "recover-binary", args.count == 5 {
            let journal = LAABrainSaveJournal(directory: URL(fileURLWithPath: args[3], isDirectory: true))
            let vault = LAABrainSaveJournal.vaultID(root)
            let oldPath = args[4]
            let binary = Data([0xff, 0xfe, 0x80, 0x00])
            _ = try journal.record(vault: vault, path: oldPath, kind: .displaced, bytes: binary)
            try FileManager.default.removeItem(at: root.appendingPathComponent(oldPath))
            let catalogue = try journal.catalogue(vault: vault)
            guard let version = catalogue.notes.first(where: { $0.path == oldPath })?.versions.first(where: { $0.kind == .displaced }),
                  case let .restored(path) = try LAABrainSaveCoordinator(journal: journal).restoreCopy(root: root, summary: version) else { throw FixtureFailure() }
            try check(tryData(root.appendingPathComponent(path)) == binary, "recovered bytes differ")
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["path": path]), as: UTF8.self))
            return
        }
        if args[1] == "fallback", args.count == 6 {
            let journal = LAABrainSaveJournal(directory: URL(fileURLWithPath: args[3], isDirectory: true))
            var coordinator = LAABrainSaveCoordinator(journal: journal)
            coordinator.fixtureForceFallback = true
            let snapshot = try coordinator.begin(root: root, path: args[4])
            guard case .saved(.checkedReplacement) = try coordinator.save(root: root, snapshot: snapshot, draft: Data(args[5].utf8)) else { throw FixtureFailure() }
            print("PASS: checked fallback")
            return
        }
        guard args[1] == "race", args.count == 7 || args.count == 8 else { throw FixtureFailure() }
        let journal = LAABrainSaveJournal(directory: URL(fileURLWithPath: args[3], isDirectory: true))
        var coordinator = LAABrainSaveCoordinator(journal: journal)
        let path = args[4]
        let snap = try coordinator.begin(root: root, path: path)
        if args.count == 8, args[7] == "change-metadata" {
            coordinator.fixtureStagePrepared = { stage in
                try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 946684800),
                                                       .posixPermissions: 0o600], ofItemAtPath: stage.path)
                let value = Data("changed-xattr".utf8)
                let result = value.withUnsafeBytes { bytes in
                    setxattr(stage.path, "com.laa.fixture", bytes.baseAddress, bytes.count, 0, 0)
                }
                guard result == 0 else { throw FixtureFailure() }
            }
        }
        coordinator.fixtureAfterComparison = { try Data(args[6].utf8).write(to: root.appendingPathComponent(path)) }
        let outcome = try coordinator.save(root: root, snapshot: snap, draft: Data(args[5].utf8))
        guard case let .intervening(displaced, draft) = outcome else { throw FixtureFailure() }
        let versions = try journal.versions(vault: snap.vault, path: path)
        try check(displaced == Data(args[6].utf8) && draft == Data(args[5].utf8), "intervening and draft mismatch")
        try check(versions.contains { $0.kind == .displaced && $0.bytes == displaced }, "displaced journal entry missing")
        let json: [String: Any] = ["outcome": "intervening", "journalKinds": versions.map { $0.kind.rawValue }]
        print(String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self))
    }

}
#endif
