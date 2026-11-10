#if LAA_BUILD
import XCTest

final class LAAStudioUITests: XCTestCase {
    private func helper(_ route: String) throws -> String {
        String(data: try Data(contentsOf: URL(string: "http://127.0.0.1:19583/\(route)")!), encoding: .utf8) ?? ""
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        let textView = app.textViews["laa.studio.composer.field"]
        if textView.waitForExistence(timeout: 3) { return textView }
        let field = app.textFields["laa.studio.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); return field
    }

    func testWorksRequestsApprovalAndNewRequestThroughMockBridge() throws {
        guard (try? helper("health")) == "ok" else { throw XCTSkip("Start scripts/laa/studio-ui-fixture.mjs first") }
        _ = try helper("reset")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "studio", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:19582"
        app.launch()
        let connect = app.buttons["laa.studio.pair"]
        XCTAssertTrue(connect.waitForExistence(timeout: 30)); connect.tap()
        let address = app.textFields["laa.bridge.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertEqual(address.value as? String, "http://127.0.0.1:19582")
        let code = app.secureTextFields["laa.bridge.code"]
        code.tap(); code.typeText("TEST-TEST")
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        pair.tap()
        let work = app.buttons["laa.studio.work.70175325-5cf4-421f-8a6f-95beae8fca92"]
        XCTAssertTrue(work.waitForExistence(timeout: 30)); work.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "laa.studio.gallery").firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let request = app.buttons["laa.studio.request.0f6b1c2e-6f1a-4c55-9d43-0d5f6f3b8a11"]
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        XCTAssertTrue(request.label.contains("確認")); request.tap()
        XCTAssertTrue(app.staticTexts["サービス紹介資料"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["laa.studio.deliverables"].exists)
        let stop = app.buttons["laa.studio.stop"]
        if !stop.isHittable { app.swipeUp() }
        XCTAssertTrue(stop.waitForExistence(timeout: 10)); stop.tap()
        let stopConfirmation = app.sheets.firstMatch
        XCTAssertTrue(stopConfirmation.waitForExistence(timeout: 10))
        XCTAssertTrue(stopConfirmation.buttons["停止"].exists)
        if app.buttons["キャンセル"].exists {
            app.buttons["キャンセル"].tap()
        } else {
            let dismiss = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismiss.exists)
            dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertFalse(stopConfirmation.waitForExistence(timeout: 2))
        let allow = app.buttons["laa.studio.approval.allow"]
        if !allow.isHittable { app.swipeDown() }
        _ = try helper("mode/action-fail-once")
        XCTAssertTrue(allow.waitForExistence(timeout: 10)); allow.tap()
        let retry = app.buttons["laa.studio.action.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 18))
        XCTAssertEqual(try helper("action-count"), "1")
        if !stop.isHittable { app.swipeUp() }
        XCTAssertTrue(stop.isEnabled)
        if !retry.isHittable { app.swipeDown() }
        retry.tap()
        XCTAssertTrue(app.staticTexts["元の操作を確認中です。少し待ってから再試行してください。"].waitForExistence(timeout: 10))
        XCTAssertEqual(try helper("action-count"), "1")
        XCTAssertEqual(try helper("action-requests"), "2")
        _ = try helper("advance-clock/61001")
        XCTAssertTrue(retry.waitForExistence(timeout: 18))
        if !retry.isHittable { app.swipeDown() }
        retry.tap()
        let reenter = app.buttons["入力し直す"]
        XCTAssertTrue(reenter.waitForExistence(timeout: 18))
        XCTAssertEqual(try helper("action-count"), "1")
        XCTAssertEqual(try helper("action-requests"), "3")
        if !reenter.isHittable { app.swipeDown() }
        reenter.tap()
        if !allow.isHittable { app.swipeDown() }
        XCTAssertTrue(allow.waitForExistence(timeout: 10)); allow.tap()
        XCTAssertTrue(app.staticTexts["制作中"].waitForExistence(timeout: 10))
        XCTAssertEqual(try helper("action-count"), "2")
        XCTAssertEqual(try helper("action-requests"), "4")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let body = composer(app)
        body.tap(); body.typeText("Make a short overview")
        app.buttons["laa.studio.kind.資料"].tap()
        XCTAssertFalse(app.buttons["laa.studio.composer.textSize"].exists)
        let send = app.buttons["laa.studio.composer.send"]
        if !send.isHittable { app.swipeUp() }
        _ = try helper("mode/create-queued")
        XCTAssertTrue(send.waitForExistence(timeout: 10)); XCTAssertGreaterThanOrEqual(send.frame.height, 44); send.tap()
        XCTAssertTrue(app.staticTexts["順番待ち"].waitForExistence(timeout: 15))
        XCTAssertFalse(send.isEnabled)
        XCTAssertFalse(app.navigationBars["制作を依頼"].exists)
        XCTAssertEqual(try helper("create-count"), "1")
    }

    func testV2ReviewRetryAndLibraryThroughMockBridge() throws {
        guard (try? helper("health")) == "ok" else { throw XCTSkip("Start scripts/laa/studio-ui-fixture.mjs first") }
        _ = try helper("reset")
        _ = try helper("mode/v2")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "studio", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:19582"
        app.launch()
        let connect = app.buttons["laa.studio.pair"]
        XCTAssertTrue(connect.waitForExistence(timeout: 30)); connect.tap()
        let address = app.textFields["laa.bridge.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertEqual(address.value as? String, "http://127.0.0.1:19582")
        let code = app.secureTextFields["laa.bridge.code"]
        code.tap(); code.typeText("TEST-TEST")
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        pair.tap()
        let work = app.buttons["laa.studio.work.70175325-5cf4-421f-8a6f-95beae8fca92"]
        XCTAssertTrue(work.waitForExistence(timeout: 30)); work.tap()
        let gallery = app.descendants(matching: .any).matching(identifier: "laa.studio.gallery").firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 10)); gallery.swipeLeft()
        let adopt = app.buttons["laa.studio.adopt"]
        if !adopt.isHittable { app.swipeUp() }
        _ = try helper("mode/v2-review-lost")
        XCTAssertTrue(adopt.waitForExistence(timeout: 10)); adopt.tap()
        XCTAssertTrue(app.staticTexts["採用を確認できません。もう一度押して確認してください"].waitForExistence(timeout: 20))
        adopt.tap()
        XCTAssertTrue(app.buttons["採用済み"].waitForExistence(timeout: 20))
        XCTAssertEqual(try helper("review-count"), "1")
        let revise = composer(app)
        XCTAssertTrue(revise.exists)
        XCTAssertFalse(app.navigationBars["制作を依頼"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let menu = app.buttons["laa.studio.menu"]
        if !menu.isHittable { app.swipeUp() }
        menu.tap(); app.buttons["ライブラリ"].tap()
        let principle = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sample")).firstMatch
        XCTAssertTrue(principle.waitForExistence(timeout: 10)); principle.tap()
        XCTAssertTrue(app.staticTexts["Fixture principle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["この原則で始める"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let document = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sample document")).firstMatch
        if !document.isHittable { app.swipeUp() }
        XCTAssertTrue(document.waitForExistence(timeout: 10)); document.tap()
        XCTAssertTrue(app.staticTexts["アプリ用の資料を読み込めません。Driveで開いてください。"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "laa.studio.document.drive").firstMatch.exists)
    }

    func testImageVideoDocumentAndOtherRequestKinds() throws {
        guard (try? helper("health")) == "ok" else { throw XCTSkip("Start scripts/laa/studio-ui-fixture.mjs first") }
        _ = try helper("reset")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "studio", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:19582"
        app.launch()
        XCTAssertTrue(app.buttons["laa.studio.pair"].waitForExistence(timeout: 30)); app.buttons["laa.studio.pair"].tap()
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10)); code.tap(); code.typeText("TEST-TEST")
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }; pair.tap()
        for (kind, prompt) in [("画像", "image"), ("動画", "video"), ("資料", "document"), ("", "automatic")] {
            let input = composer(app)
            if !input.isHittable { app.swipeDown() }
            input.tap(); input.typeText("Fixture " + prompt)
            if !kind.isEmpty { app.buttons["laa.studio.kind." + kind].tap() }
            if kind == "画像" {
                app.buttons["参考を添付"].tap(); app.buttons["Driveから選ぶ"].tap()
                let reference = app.buttons["Reference.png"]
                XCTAssertTrue(reference.waitForExistence(timeout: 15)); reference.tap()
                XCTAssertTrue(app.staticTexts["Reference.png"].waitForExistence(timeout: 10))
            }
            let send = app.buttons["laa.studio.composer.send"]
            if !send.isHittable { app.swipeUp() }; send.tap()
            let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: send)
            XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 15), .completed)
            XCTAssertFalse(app.navigationBars["制作を依頼"].exists)
        }
        XCTAssertEqual(try helper("create-count"), "4")
        XCTAssertEqual(try helper("create-reference"), "1")
        XCTAssertEqual(try helper("create-kinds"), "画像,動画,資料")
    }

    func testDocumentShowsLoadingWhileDriveRetrievesIt() throws {
        guard (try? helper("health")) == "ok" else { throw XCTSkip("Start scripts/laa/studio-ui-fixture.mjs first") }
        _ = try helper("reset"); _ = try helper("mode/v2-document-wait")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "studio", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:19582"
        app.launch()
        XCTAssertTrue(app.buttons["laa.studio.pair"].waitForExistence(timeout: 30)); app.buttons["laa.studio.pair"].tap()
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10)); code.tap(); code.typeText("TEST-TEST")
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        pair.tap()
        let menu = app.buttons["laa.studio.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30)); if !menu.isHittable { app.swipeUp() }
        menu.tap(); app.buttons["ライブラリ"].tap()
        let document = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sample document")).firstMatch
        if !document.isHittable { app.swipeUp() }
        XCTAssertTrue(document.waitForExistence(timeout: 10)); document.tap()
        let loading = app.descendants(matching: .any).matching(identifier: "laa.studio.document.loading").firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 3))
        XCTAssertTrue(loading.label.contains("資料を読み込み中"))
        let loadingScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        loadingScreenshot.name = "Studio document - loading"
        loadingScreenshot.lifetime = .keepAlways
        add(loadingScreenshot)
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading)
        wait(for: [gone], timeout: 15)
        XCTAssertFalse(app.staticTexts["プレビューを開けません。Driveの納品を確認してください。"].exists)
    }
}
#endif
