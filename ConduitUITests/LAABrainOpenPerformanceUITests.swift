#if LAA_BUILD && DEBUG && targetEnvironment(simulator)
import QuartzCore
import XCTest

final class LAABrainOpenPerformanceUITests: XCTestCase {
    func testColdAndWarmFileOpen() throws {
        let runs = ProcessInfo.processInfo.environment["LAA_DOC_BENCHMARK"] == "1" ? 5 : 1
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-laa-brain-local-fixture", "-laa-brain-open-benchmark"]
        defer { app.terminate() }
        for run in 1...runs {
            for size in ["Small", "Medium", "Large"] {
                if app.state != .notRunning { app.terminate() }
                app.launchInLab()
                let folder = app.staticTexts["Company"].firstMatch
                XCTAssertTrue(folder.waitForExistence(timeout: 20))
                folder.tap()
                let item = app.buttons.matching(identifier: "laa.brain.note").containing(.staticText, identifier: size).firstMatch
                for temperature in ["cold", "warm"] {
                    XCTAssertTrue(item.waitForExistence(timeout: 15))
                    let start = CACurrentMediaTime()
                    item.tap()
                    let body = app.textViews["laa.brain.edit.text"].firstMatch
                    XCTAssertTrue(body.waitForExistence(timeout: 20))
                    XCTAssertTrue((body.value as? String ?? "").contains("End of \(size) fixture."))
                    let elapsed = (CACurrentMediaTime() - start) * 1000
                    print("LAA_DOC_OPEN \(run) \(size) \(temperature) \(elapsed)")
                    let back = app.buttons["laa.brain.back"].firstMatch
                    XCTAssertTrue(back.waitForExistence(timeout: 15)); back.tap()
                }
            }
        }
    }
}
#endif
