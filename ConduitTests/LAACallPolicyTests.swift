#if LAA_BUILD
import XCTest
@testable import Conduit

/// An employee calls the owner when asked. Calling on its own judgment and
/// calling about approvals stay off unless the owner turns them on, and the
/// Mac's own notifications are chosen kind by kind.
@MainActor
final class LAACallPolicyTests: XCTestCase {
    func testAnEmployeeCallsOnlyWhenAskedUnlessTheOwnerSaysOtherwise() {
        let settings = HermesCallSettings()
        XCTAssertTrue(settings.whenAsked)
        XCTAssertNil(settings.decides)
        XCTAssertNil(settings.alerts)
        // Saving the defaults never turns either on at the host.
        XCTAssertNil(settings.payload["decides"])
        XCTAssertNil(settings.payload["alerts"])
    }

    func testTheHostsOffSwitchesSurviveAReadAndASave() throws {
        let host: [String: Any] = ["enabled": true, "when_asked": true, "decides": false, "alerts": false,
                                   "min_gap_s": 120, "per_hour": 6, "per_day": 20]
        let settings = try XCTUnwrap(HermesCallSettings(json: host))
        XCTAssertEqual(settings.payload["decides"] as? Bool, false)
        XCTAssertEqual(settings.payload["alerts"] as? Bool, false)
        XCTAssertEqual(settings.payload["when_asked"] as? Bool, true)
        // With those off, a call the owner asked for is still available.
        let status = try XCTUnwrap(HermesCallsStatus.parse(["ok": true, "paired": true, "settings": host]))
        XCTAssertEqual(status.callbackAvailability, .available)
        var off = host
        off["when_asked"] = false
        XCTAssertEqual(HermesCallsStatus.parse(["ok": true, "paired": true, "settings": off])?.callbackAvailability, .whenAskedOff)
    }

    // MARK: Which of the Mac's notifications arrive

    func testPreferencesDecodeAndAnUnknownLevelIsNeverSilence() throws {
        let decoded = try JSONDecoder().decode(LAAWorkNotificationPreferences.self, from: Data("""
        { "kinds": { "decision": "alert", "question": "alert", "approval": "alert", "error": "alert",
                     "finished": "quiet", "task": "off", "calendar": "later" }, "updatedAt": null }
        """.utf8))
        XCTAssertEqual(decoded.level("finished"), .quiet)
        XCTAssertEqual(decoded.level("task"), .off)
        XCTAssertEqual(decoded.level("calendar"), .alert)
        XCTAssertEqual(decoded.level("missing"), .alert)
    }

    func testWhatTheOwnerMustAnswerCannotBeTurnedOff() {
        let kinds = LAAWorkNotificationPreferences.kinds
        XCTAssertEqual(kinds.map(\.id), ["decision", "question", "approval", "error", "finished", "task", "calendar"])
        for kind in kinds where ["decision", "question", "approval"].contains(kind.id) {
            XCTAssertEqual(kind.levels, [.alert, .quiet])
        }
        XCTAssertEqual(kinds.first { $0.id == "finished" }?.levels, [.alert, .quiet, .off])
    }

    func testOneChangeSendsOnlyThatKind() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: LAAWorkNotificationSettingsModel.body(kind: "finished", level: .off)) as? [String: Any])
        XCTAssertEqual(body["kinds"] as? [String: String], ["finished": "off"])
        XCTAssertEqual(body.count, 1)
    }
}
#endif
