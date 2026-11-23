import XCTest

final class LAAWatchUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private func home(longJapanese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-watch-lab", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        if longJapanese {
            app.launchArguments.append("-laa-watch-lab-long-ja")
            if env["LAA_WATCH_LAB_FORCE_AX5"] == "1" { app.launchArguments.append("-laa-watch-lab-force-ax5") }
        }
        app.launch()
        XCTAssertTrue(app.buttons["watch.home.talk"].waitForExistence(timeout: 20))
        return app
    }

    func testHome() throws {
        let variant = try XCTUnwrap(env["LAA_WATCH_LAB_VARIANT"])
        let expectedAppearance = try XCTUnwrap(env["LAA_WATCH_LAB_APPEARANCE"])
        let long = variant == "long-ja-ax5"
        let app = home(longJapanese: long)
        let actual = try XCTUnwrap(app.buttons["watch.home.talk"].value as? String)
        XCTAssertTrue(["dark", "light"].contains(String(actual.split(separator: "|")[0])))
        if expectedAppearance != "native" {
            XCTAssertTrue(actual.hasPrefix(expectedAppearance + "|"), "SwiftUI reported \(actual)")
        }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'watch.home.staff.'"))
            .firstMatch.waitForExistence(timeout: 10))
        if long { XCTAssertTrue(actual.hasSuffix("|ax5"), "SwiftUI reported \(actual)") }
        shot(app, "home")
        let proof = XCTAttachment(string: actual)
        proof.name = "watch-appearance-proof"
        proof.lifetime = .keepAlways
        add(proof)
    }

    func testPhoneContext() throws {
        let initial = try XCTUnwrap(env["LAA_WATCH_LAB_INITIAL"])
        let next = try XCTUnwrap(env["LAA_WATCH_LAB_NEXT"])
        let app = home()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'watch.home.staff.'")).firstMatch.tap()
        let talk = app.buttons["watch.employee.talk"]
        let call = app.buttons["watch.employee.call"]
        requireContext(initial, on: talk)
        XCTAssertFalse(call.exists, "The first phone context excludes this employee from Call")
        shot(app, "employee-no-call")

        // The host starts the phone sender only after the first context and
        // its visible effect have both been observed, not after a timed sleep.
        try Data().write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("laa-watch-lab-\(next).ready"), options: .atomic)
        requireContext(next, on: talk)
        XCTAssertTrue(call.exists, "The second phone context makes Call appear; never tap it")
        shot(app, "employee-call-available")
    }

    private func requireContext(_ nonce: String, on element: XCUIElement) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == YES AND value == %@", nonce), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 45), .completed,
                       "No fresh phone application context arrived (actual \(String(describing: element.value)))")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "watch-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
