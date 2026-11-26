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
        XCTAssertEqual(kinds.map(\.id), ["decision", "question", "approval", "error", "report", "finished", "task", "calendar"])
        for kind in kinds where ["decision", "question", "approval"].contains(kind.id) {
            XCTAssertEqual(kind.levels, [.alert, .quiet])
        }
        XCTAssertEqual(kinds.first { $0.id == "finished" }?.levels, [.alert, .quiet, .off])
    }

    /// A Bridge with Monet's report lane: its own defaults (finished off) and
    /// the owner's explicit choices are shown as the Mac holds them.
    func testTheReportRowFollowsTheMacAndKeepsTheOwnersChoices() throws {
        let fresh = try JSONDecoder().decode(LAAWorkNotificationPreferences.self, from: Data("""
        { "kinds": { "decision": "alert", "question": "alert", "approval": "alert", "error": "alert",
                     "finished": "off", "report": "alert", "task": "alert", "calendar": "alert" }, "updatedAt": null }
        """.utf8))
        XCTAssertEqual(fresh.shownKinds.map(\.id), LAAWorkNotificationPreferences.kinds.map(\.id))
        XCTAssertEqual(fresh.level("finished"), .off)
        XCTAssertEqual(fresh.level("report"), .alert)
        XCTAssertEqual(fresh.shownKinds.first { $0.id == "report" }?.title, "Monetの報告")
        XCTAssertTrue(fresh.canChange("report", to: .quiet))
        XCTAssertTrue(fresh.canChange("report", to: .off))

        let chosen = try JSONDecoder().decode(LAAWorkNotificationPreferences.self, from: Data("""
        { "kinds": { "decision": "quiet", "question": "alert", "approval": "alert", "error": "off",
                     "finished": "quiet", "report": "off", "task": "alert", "calendar": "alert" }, "updatedAt": "2026-11-25T08:00:00.000Z" }
        """.utf8))
        XCTAssertEqual(chosen.level("finished"), .quiet)
        XCTAssertEqual(chosen.level("report"), .off)
        XCTAssertEqual(chosen.level("decision"), .quiet)
        XCTAssertEqual(chosen.level("error"), .off)
        XCTAssertFalse(chosen.canChange("decision", to: .off))
    }

    /// An older Bridge does not list `report` and rejects it: no row, no change sent.
    func testAnOlderMacShowsNoReportRowAndAcceptsNoReportChange() throws {
        let legacy = try JSONDecoder().decode(LAAWorkNotificationPreferences.self, from: Data("""
        { "kinds": { "decision": "alert", "question": "alert", "approval": "alert", "error": "alert",
                     "finished": "quiet", "task": "alert", "calendar": "alert" }, "updatedAt": null }
        """.utf8))
        XCTAssertEqual(legacy.shownKinds.map(\.id), ["decision", "question", "approval", "error", "finished", "task", "calendar"])
        XCTAssertFalse(legacy.canChange("report", to: .off))
        XCTAssertTrue(legacy.canChange("finished", to: .off))
        XCTAssertEqual(legacy.level("finished"), .quiet)
        XCTAssertFalse(legacy.canChange("unknown", to: .alert))
    }

    func testAnUnsupportedChangeNeverReachesTheMac() async {
        let model = LAAWorkNotificationSettingsModel()
        model.setForTesting(.init(kinds: ["decision": .alert, "question": .alert, "approval": .alert, "error": .alert,
                                          "finished": .quiet, "task": .alert, "calendar": .alert]))
        // "Paired" without credentials: any request would fail and move the phase
        // off `.loaded`, so an unchanged model shows none was attempted.
        await model.set("report", to: .off, bridge: LAABridgeSession(statusForTesting: .paired))
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertNil(model.preferences.kinds["report"])
        XCTAssertNil(model.saving)
    }

    func testOneChangeSendsOnlyThatKind() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: LAAWorkNotificationSettingsModel.body(kind: "finished", level: .off)) as? [String: Any])
        XCTAssertEqual(body["kinds"] as? [String: String], ["finished": "off"])
        XCTAssertEqual(body.count, 1)
    }
}
#endif
