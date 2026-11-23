#if LAA_BUILD
import QuartzCore
import XCTest

/// Lab only: real app surfaces with an inert Hermes stub and the local Work
/// fixture. Every XCTest invocation contributes at most one sample per probe.
final class LAAPerformanceUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let longID = "work.session.ses_3333333333333333"

    override func setUpWithError() throws {
        guard env["LAA_PERF_RUN"] == "1" else { throw XCTSkip("Run scripts/laa/lab/perf.py run") }
        continueAfterFailure = false
    }

    private func application(chatFixture: Bool = false) throws -> XCUIApplication {
        let port = try XCTUnwrap(Int(env["LAA_PERF_PORT"] ?? ""))
        let namespace = try XCTUnwrap(env["LAA_PERF_NAMESPACE"].flatMap(UUID.init(uuidString:)))
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-LAA_UI_TEST_PAIR_CODE", "TEST-TEST",
                               "-laa.work.lastProject", "", "-conduit.themePreference", "light",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://perf-lab.invalid",
                               "-laa-brain-local-fixture", "-laa-brain-document-fixture"]
        if chatFixture {
            app.launchArguments += ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "long120",
                                    "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "paper", "-LAA_FIXTURE_PUSH_CHAT"]
        }
        app.launchEnvironment = ["LAA_PERF_KEYCHAIN_NAMESPACE": namespace.uuidString,
                                 "LAA_BRIDGE_DEFAULT_ADDRESS": "http://127.0.0.1:\(port)"]
        return app
    }

    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        return options
    }

    func testColdLaunch() throws {
        let app = try application()
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            if app.state != .notRunning { app.terminate() }
            app.launch()
            XCTAssertTrue(app.buttons["work.section.sessions"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["work.section.sessions"].isHittable)
        }
        app.terminate()
    }

    private enum Destination: String, CaseIterable {
        case work, today, doc, usage, chat
        var tabIndex: Int? {
            switch self {
            case .chat: return 0
            case .work: return 1
            case .today: return 2
            case .doc: return 3
            case .usage: return nil // Work pushes Usage; it isn't a native tab.
            }
        }
        var marker: String {
            switch self {
            case .work: return "work.section.sessions"
            case .today: return "laa.today.title"
            case .doc: return "laa.brain.title"
            case .usage: return "laa.usage.refresh"
            case .chat: return "laa.chats.list"
            }
        }
    }

    private func item(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func usable(_ target: Destination, _ app: XCUIApplication) {
        XCTAssertTrue(item(target.marker, app).waitForExistence(timeout: 15), "Destination \(target.rawValue) not mounted")
        if let index = target.tabIndex {
            XCTAssertTrue(app.tabBars.buttons.element(boundBy: index).isSelected, "Wrong native tab for \(target.rawValue)")
        }
    }

    private func move(_ source: Destination, _ target: Destination, _ app: XCUIApplication) {
        if source == .usage { app.buttons["BackButton"].firstMatch.tap() }
        if let index = target.tabIndex {
            if source != .usage || target != .work { app.tabBars.buttons.element(boundBy: index).tap() }
        } else {
            if source != .work {
                app.tabBars.buttons.element(boundBy: Destination.work.tabIndex!).tap()
                usable(.work, app)
            }
            app.buttons["work.usage"].tap()
        }
        usable(target, app)
    }

    private func sample(_ name: String, _ body: () -> Void) {
        let began = CACurrentMediaTime()
        body()
        let ms = (CACurrentMediaTime() - began) * 1000
        print("LAA_LAB_PERF {\"probe\":\"\(name)\",\"ms\":\(ms)}")
    }

    func testNavigationAndOpen() throws {
        let app = try application()
        app.launch()
        usable(.work, app)
        // Make the warm measurement distinct from a fresh process launch.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 15))
        sample("warm_activate") { app.activate(); usable(.work, app) }

        // For five destinations, four full cycles with distinct step sizes
        // visit each directed pair exactly once and finish back at Work.
        let order = Destination.allCases
        for step in 1..<order.count {
            var from = 0
            for _ in order {
                let to = (from + step) % order.count
                sample("nav_\(order[from].rawValue)_to_\(order[to].rawValue)") { move(order[from], order[to], app) }
                from = to
            }
        }
        move(.work, .doc, app)
        let note = app.staticTexts["Start"].firstMatch // Title of this fixed synthetic document.
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        sample("doc_open_long") {
            note.tap()
            let editor = app.textViews["laa.brain.edit.text"].firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 15))
            XCTAssertTrue((editor.value as? String ?? "").contains("段落45"), "The long document body, not just its shell, must be present")
        }
        app.buttons["laa.brain.back"].firstMatch.tap()
        move(.doc, .work, app)
        openSessionList(app)
        let session = app.staticTexts[longID].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15))
        sample("work_open_long_history") {
            session.tap()
            XCTAssertTrue(item("work.session.history.ready", app).waitForExistence(timeout: 25))
            XCTAssertTrue(app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS 'S62M'")).firstMatch.waitForExistence(timeout: 15),
                "The 62nd message is a fixture data assertion, not a control lookup")
        }
        app.terminate()
    }

    private func openSessionList(_ app: XCUIApplication) {
        let sessions = app.buttons["work.section.sessions"].firstMatch
        XCTAssertTrue(sessions.waitForExistence(timeout: 15))
        sessions.tap()
        XCTAssertTrue(app.staticTexts[longID].firstMatch.waitForExistence(timeout: 25))
    }

    private func measureScroll(in app: XCUIApplication, body: () -> Void) throws {
        // Simulators may export a duration but no frame counters for the
        // scrolling signpost. Request application hitches directly too.
        guard #available(iOS 26.0, *) else { throw XCTSkip("XCTHitchMetric requires iOS 26") }
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTHitchMetric(application: app)],
                options: options, block: body)
    }

    func testScrollChat() throws {
        let app = try application(chatFixture: true)
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
        let scroller = item("chat.transcript", app)
        XCTAssertTrue(scroller.waitForExistence(timeout: 20))
        let tail = scroller.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "長い会話の120件目")).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 10))
        func towardEarlier() {
            scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                .press(forDuration: 0.05, thenDragTo: scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)),
                       withVelocity: .fast, thenHoldForDuration: 0)
        }
        let tailY = tail.frame.minY
        towardEarlier()
        XCTAssertTrue(!tail.exists || tail.frame.minY > tailY + 10, "Long Chat must actually scroll")
        scroller.swipeUp(velocity: .fast)
        try measureScroll(in: app) {
            towardEarlier()
            scroller.swipeUp(velocity: .fast)
        }
        app.terminate()
    }

    func testScrollWork() throws {
        let app = try application()
        app.launch()
        openSessionList(app)
        let scroller = try XCTUnwrap(app.scrollViews.allElementsBoundByIndex.first { $0.frame.height > 400 })
        let anchor = app.staticTexts[longID].firstMatch
        let before = anchor.frame.minY
        scroller.swipeUp(velocity: .fast)
        XCTAssertTrue(!anchor.exists || anchor.frame.minY < before - 10, "Work list must actually scroll")
        scroller.swipeDown(velocity: .fast)
        try measureScroll(in: app) {
            scroller.swipeUp(velocity: .fast)
            scroller.swipeDown(velocity: .fast)
        }
        app.terminate()
    }
}
#endif
