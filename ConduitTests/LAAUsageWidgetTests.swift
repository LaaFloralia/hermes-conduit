#if LAA_BUILD
import Foundation
import XCTest
@testable import Conduit

@MainActor
final class LAAUsageWidgetTests: XCTestCase {
    private func item(_ id: String, _ values: [Double], stale: Bool = false) throws -> LAAUsageItem {
        let windows = values.enumerated().map { index, value in
            ["label": "Window \(index)", "remainingPercent": value,
             "resetsAt": "2030-01-01T00:00:00Z"] as [String: Any]
        }
        let json: [String: Any] = [
            "id": "provider.\(id).quota", "kind": "quota", "label": id,
            "value": values.first ?? 0, "unit": "percent", "source": "codexbar-usage-proxy",
            "observedAt": "2026-10-31T00:00:00Z", "availability": "available", "stale": stale,
            "estimated": false, "expired": false,
            "detail": ["windows": windows, "freshUntil": "2026-10-31T00:20:00Z"]
        ]
        return try JSONDecoder().decode(LAAUsageItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testLowestThreeWindowsKeepZeroAndDoNotIncludeHiddenProviders() throws {
        let items = try [item("claude", [25, 0]), item("codex", [10]), item("opencode-go", [50]), item("grok-bot", [1])]
        let result = LAAWidgetUsageBuilder.make(items: items, retained: ["provider.codex.quota"], failed: false, checkedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(result.meters.map(\.remainingPercent), [0, 10, 25])
        XCTAssertEqual(result.checkedAt, LAAUsageItem.date("2026-10-31T00:00:00Z"))
        XCTAssertTrue(result.meters[1].retained)
        let fresh = try XCTUnwrap(LAAUsageItem.date("2026-10-31T00:10:00Z"))
        let expired = try XCTUnwrap(LAAUsageItem.date("2026-10-31T00:21:00Z"))
        XCTAssertFalse(result.meters[0].isPast(at: fresh))
        XCTAssertTrue(result.meters[0].isPast(at: expired))
        XCTAssertTrue(result.meters[1].isPast(at: fresh))
    }

    func testSnapshotCacheSurvivesOtherPublicationsAndCanBeCleared() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        let summary = LAAWidgetUsageBuilder.make(items: [try item("claude", [42])], retained: [], failed: false, checkedAt: Date())
        XCTAssertTrue(try store.writeUsage(summary))
        let old = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: nil, workspaces: [])
        XCTAssertTrue(try store.write(old))
        XCTAssertEqual(store.read()?.usage, summary)
        XCTAssertTrue(try store.writeUsage(nil))
        XCTAssertNil(store.read()?.usage)
        XCTAssertEqual(store.read()?.appLanguage, "en")
        let encodedOld = Data("{\"schemaVersion\":1,\"appLanguage\":\"ja\",\"workspaces\":[]}".utf8)
        XCTAssertNil(try JSONDecoder().decode(WidgetSnapshot.self, from: encodedOld).usage)
    }

    func testConsoleOrderAndHermesRowsAreExcluded() throws {
        let items = try [item("codex", [30]), item("claude", [20]), item("opencode-go", [40]), item("grok-bot", [2])]
        XCTAssertEqual(LAAUsageGroup.consoleGroups(items).map(\.id), ["provider.claude", "provider.codex", "provider.opencode-go"])
        let summary = LAAWidgetUsageBuilder.make(items: items, retained: [], failed: true, checkedAt: nil)
        XCTAssertTrue(summary.meters.allSatisfy(\.retained))
    }
}
#endif
