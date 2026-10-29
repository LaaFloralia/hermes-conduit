import XCTest

final class LAANotificationPairAllUITests: XCTestCase {
    #if LAA_BUILD
    func testButtonAvailabilityAndRetry() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-LAA_UI_TEST_PAIR_ALL"]
        app.launch()
        let pair = app.buttons["notifications.pair-all"]
        XCTAssertTrue(pair.waitForExistence(timeout: 20))
        XCTAssertFalse(pair.isEnabled)
        app.buttons["pair-all.fixture.connection"].tap()
        XCTAssertTrue(pair.isEnabled)
        pair.tap()
        XCTAssertFalse(pair.isEnabled)
        let retry = app.buttons["notifications.pair-all.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: retry)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "既にこのiPhone")).firstMatch.exists)
        retry.tap()
        XCTAssertFalse(pair.isEnabled)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: retry)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 15), .completed)
        let retried = app.descendants(matching: .any)["notifications.pair-all.result.laa-cmo"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "済"), object: retried)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 15), .completed)
        XCTAssertTrue(pair.isEnabled)
    }
    #else
    func testOnlyAvailableInLAABuild() throws { throw XCTSkip("LAA build only") }
    #endif
}
