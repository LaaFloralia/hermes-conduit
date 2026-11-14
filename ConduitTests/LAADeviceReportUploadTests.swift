#if LAA_BUILD
import XCTest
@testable import Conduit

/// Crash and hang diagnostics reach the paired Mac once each, without the
/// owner sharing anything, and a failed send is tried again later.
final class LAADeviceReportUploadTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        var accept = true
        func record(_ name: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            names.append(name)
            return accept
        }
        var sent: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

    private func store() -> MetricKitReportStore {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("laa-device-reports-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        var store = MetricKitReportStore(directory: folder)
        store.exportDirectory = folder
        return store
    }

    private func crash(_ n: Int) -> Data {
        Data(#"{"crashDiagnostics":[{"callStackTree":{"n":\#(n)}}]}"#.utf8)
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testEachDiagnosticIsSentOnceAndAFailureIsRetried() {
        let store = store()
        let day = Date(timeIntervalSince1970: 1_790_812_800)
        XCTAssertTrue(store.save(crash(1), kind: .diagnostics, begin: day, end: day.addingTimeInterval(60)))
        XCTAssertTrue(store.save(crash(2), kind: .diagnostics, begin: day.addingTimeInterval(120), end: day.addingTimeInterval(180)))
        let names = store.entries(.diagnostics).map(\.url.lastPathComponent)
        let reports = MetricKitReports(store: store)

        // Offline: the first fails, nothing is marked, the second waits.
        let recorder = Recorder()
        recorder.accept = false
        reports.sendDiagnostics { name, _ in recorder.record(name) }
        waitFor { recorder.sent.count == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(recorder.sent, [names[0]])
        XCTAssertEqual(store.sentDiagnosticNames(), [])

        recorder.accept = true
        reports.sendDiagnostics { name, _ in recorder.record(name) }
        waitFor { store.sentDiagnosticNames().count == 2 }
        XCTAssertEqual(store.sentDiagnosticNames(), Set(names))
        XCTAssertEqual(recorder.sent, [names[0], names[0], names[1]])

        // Nothing new: nothing is sent again.
        reports.sendDiagnostics { name, _ in recorder.record(name) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(recorder.sent.count, 3)
        // The sent list is not a report.
        XCTAssertEqual(store.entries(.diagnostics).count, 2)
    }

    func testTheBodyCarriesThePayloadAsWritten() throws {
        let body = try XCTUnwrap(LAADeviceReportUpload.body(name: "diagnostics-1-2-abc.json", json: crash(7), appVersion: "1.0 (1)"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "diagnostics")
        XCTAssertEqual(object["name"] as? String, "diagnostics-1-2-abc.json")
        XCTAssertEqual(object["appVersion"] as? String, "1.0 (1)")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertNotNil(payload["crashDiagnostics"])
        XCTAssertNil(LAADeviceReportUpload.body(name: "x.json", json: Data("[1]".utf8)))
        let metrics = try XCTUnwrap(LAADeviceReportUpload.body(name: "metrics-1-2-abc.json", json: crash(8), appVersion: "1.0 (1)"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: metrics) as? [String: Any])?["kind"] as? String, "metrics")
    }
}
#endif
