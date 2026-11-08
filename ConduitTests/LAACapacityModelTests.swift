#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAACapacityModelTests: XCTestCase {
    private let gib = 1_073_741_824.0

    func testBinaryUnits() {
        XCTAssertEqual(LAACapacity.bytes(80 * gib), "80 GiB")
        XCTAssertEqual(LAACapacity.bytes(12.34 * gib), "12.3 GiB")
        XCTAssertEqual(LAACapacity.bytes(0.5 * gib), "0.5 GiB")
        XCTAssertEqual(LAACapacity.bytes(1024 * gib), "1 TiB")
        XCTAssertEqual(LAACapacity.bytes(1536 * gib), "1.5 TiB")
        // A 2 TB plan in decimal bytes is 1.82 TiB, not 2.
        XCTAssertEqual(LAACapacity.bytes(2e12), "1.82 TiB")
    }

    func testSSDThresholdsAndUnknownStatus() throws {
        let ssd = { (free: Double, status: String) in
            try self.item(id: "capacity.mac-mini.ssd", total: 1024 * self.gib, free: free * self.gib, status: status,
                          warning: 80 * self.gib, critical: 40 * self.gib)
        }
        XCTAssertEqual(LAACapacity.reading(try ssd(412, "normal"))?.level, .normal)
        XCTAssertEqual(LAACapacity.reading(try ssd(60, "warning"))?.level, .warning)
        XCTAssertEqual(LAACapacity.reading(try ssd(30, "critical"))?.level, .critical)
        // The app checks the thresholds itself, and the worse answer wins.
        XCTAssertEqual(LAACapacity.reading(try ssd(30, "normal"))?.level, .critical)
        XCTAssertEqual(LAACapacity.reading(try ssd(412, "warning"))?.level, .warning)
        let reading = try XCTUnwrap(LAACapacity.reading(try ssd(412, "normal")))
        XCTAssertEqual(try XCTUnwrap(reading.warningFraction), (1024 - 80) / 1024, accuracy: 1e-12)
        // A fresh reading with no thresholds is recorded, never called normal.
        let memory = try item(id: "capacity.mac-mini.memory", total: 64 * gib, free: 38 * gib, status: "unknown")
        XCTAssertEqual(LAACapacity.reading(memory)?.level, .recorded)
    }

    func testInconsistentOrMissingNumbersShowNothing() throws {
        let total = 1024 * gib
        XCTAssertNil(LAACapacity.reading(try item(id: "capacity.mac-mini.ssd", total: total, free: 10 * gib, used: 10 * gib)))
        XCTAssertNil(LAACapacity.reading(try item(id: "capacity.mac-mini.ssd", total: 0, free: 0, used: 0)))
        XCTAssertNil(LAACapacity.reading(try item(id: "capacity.mac-mini.ssd", total: total, free: -1, used: total + 1)))
        XCTAssertNil(LAACapacity.reading(try item(id: "capacity.mac-mini.ssd", total: total, free: total + gib, used: -gib)))
        XCTAssertNil(LAACapacity.reading(try item(id: "capacity.mac-mini.ssd", total: total, free: gib, unit: "gib")))
        XCTAssertNil(LAACapacity.reading(try item(id: "capacity.mac-mini.ssd", total: total, free: gib, omitTotal: true)))
    }

    func testGoogleOverQuotaRetainsActualUseAndShowsCritical() throws {
        let google = try item(id: "capacity.google-drive", total: 30 * gib, free: 0,
                              used: 31 * gib, status: "critical")
        let reading = try XCTUnwrap(LAACapacity.reading(google))
        XCTAssertEqual(reading.usedBytes, 31 * gib)
        XCTAssertEqual(reading.availableBytes, 0)
        XCTAssertEqual(reading.level, .critical)
        XCTAssertNil(LAACapacity.reading(try item(id: "capacity.google-drive", total: 30 * gib,
                                                free: gib, used: 31 * gib)))
    }

    func testStaleAndUnavailableShowNoCurrentValue() throws {
        let now = Date()
        let old = try item(id: "capacity.mac-mini.ssd", total: 1024 * gib, free: 412 * gib,
                           observed: now.addingTimeInterval(-11 * 60), freshUntil: now.addingTimeInterval(-60))
        XCTAssertNil(LAACapacity.reading(old, at: now))
        // A later server deadline does not stretch the app's ten-minute limit.
        let stretched = try item(id: "capacity.mac-mini.ssd", total: 1024 * gib, free: 412 * gib,
                                 observed: now.addingTimeInterval(-11 * 60), freshUntil: now.addingTimeInterval(3600))
        XCTAssertNil(LAACapacity.reading(stretched, at: now))
        let early = try item(id: "capacity.mac-mini.ssd", total: 1024 * gib, free: 412 * gib,
                             observed: now.addingTimeInterval(-60), freshUntil: now.addingTimeInterval(-1))
        XCTAssertNil(LAACapacity.reading(early, at: now))
        let missing = try unavailable(id: "capacity.mac-mini.memory", reason: "fetch_failed")
        XCTAssertNil(LAACapacity.reading(missing))
        XCTAssertFalse(LAACapacity.isUnconnected(missing))
        XCTAssertTrue(LAACapacity.isUnconnected(try unavailable(id: "capacity.icloud", reason: "unsupported")))
    }

    func testCapacityStaysOutOfAIGroupsInOwnerOrder() throws {
        let rows = [try unavailable(id: "capacity.icloud", reason: "unsupported"),
                    try item(id: "capacity.google-drive", total: 2e12, free: 1.4e12),
                    try item(id: "capacity.mac-mini.memory", total: 64 * gib, free: 38 * gib)]
        XCTAssertEqual(LAACapacity.items(rows).map(\.id), ["capacity.mac-mini.memory", "capacity.google-drive", "capacity.icloud"])
        XCTAssertTrue(LAAUsageGroup.consoleGroups(rows).isEmpty)
    }

    private func item(id: String, total: Double, free: Double, used: Double? = nil, status: String = "unknown",
                      warning: Double? = nil, critical: Double? = nil, unit: String = "bytes", omitTotal: Bool = false,
                      observed: Date = Date().addingTimeInterval(-5),
                      freshUntil: Date = Date().addingTimeInterval(595)) throws -> LAAUsageItem {
        let formatter = ISO8601DateFormatter()
        var detail: [String: Any] = ["availableBytes": free, "freshUntil": formatter.string(from: freshUntil),
                                     "status": status, "warningFreeBytes": (warning as Any?) ?? NSNull(), "criticalFreeBytes": (critical as Any?) ?? NSNull()]
        if !omitTotal { detail["totalBytes"] = total }
        let row: [String: Any] = ["id": id, "kind": "capacity", "label": id, "value": used ?? total - free, "unit": unit,
                                  "source": "filesystem", "observedAt": formatter.string(from: observed),
                                  "availability": "available", "stale": false, "estimated": false, "expired": false, "detail": detail]
        return try JSONDecoder().decode(LAAUsageItem.self, from: JSONSerialization.data(withJSONObject: row))
    }

    private func unavailable(id: String, reason: String) throws -> LAAUsageItem {
        let row: [String: Any] = ["id": id, "kind": "capacity", "label": id, "value": NSNull(), "unit": "bytes",
                                  "source": "unsupported", "observedAt": NSNull(), "availability": "unavailable",
                                  "nullReason": reason, "stale": false, "estimated": false, "expired": false]
        return try JSONDecoder().decode(LAAUsageItem.self, from: JSONSerialization.data(withJSONObject: row))
    }
}
#endif
