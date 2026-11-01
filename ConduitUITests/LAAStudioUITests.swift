#if LAA_BUILD
import XCTest

final class LAAStudioUITests: XCTestCase {
    private func helper(_ route: String) throws -> String {
        String(data: try Data(contentsOf: URL(string: "http://127.0.0.1:19583/\(route)")!), encoding: .utf8) ?? ""
    }

    func testWorksRequestsApprovalAndNewRequestThroughMockBridge() throws {
        guard (try? helper("health")) == "ok" else { throw XCTSkip("Start scripts/laa/studio-ui-fixture.mjs first") }
        _ = try helper("reset")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "source", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:19582"
        app.launch()
        let studio = app.buttons["Studio"]
        XCTAssertTrue(studio.waitForExistence(timeout: 30)); studio.tap()
        let connect = app.buttons["laa.studio.pair"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10)); connect.tap()
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
        XCTAssertTrue(app.staticTexts["Cover"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Requests"].tap()
        let request = app.buttons["laa.studio.request.0f6b1c2e-6f1a-4c55-9d43-0d5f6f3b8a11"]
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        XCTAssertTrue(request.label.contains("Needs approval")); request.tap()
        XCTAssertTrue(app.staticTexts["サービス紹介資料"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["laa.studio.deliverables"].exists)
        let stop = app.buttons["laa.studio.stop"]
        if !stop.isHittable { app.swipeUp() }
        XCTAssertTrue(stop.waitForExistence(timeout: 10)); stop.tap()
        let stopConfirmation = app.sheets.firstMatch
        XCTAssertTrue(stopConfirmation.waitForExistence(timeout: 10))
        XCTAssertTrue(stopConfirmation.buttons["Stop"].exists)
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
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
        let reenter = app.buttons["Enter again"]
        XCTAssertTrue(reenter.waitForExistence(timeout: 18))
        XCTAssertEqual(try helper("action-count"), "1")
        XCTAssertEqual(try helper("action-requests"), "3")
        if !reenter.isHittable { app.swipeDown() }
        reenter.tap()
        if !allow.isHittable { app.swipeDown() }
        XCTAssertTrue(allow.waitForExistence(timeout: 10)); allow.tap()
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10))
        XCTAssertEqual(try helper("action-count"), "2")
        XCTAssertEqual(try helper("action-requests"), "4")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let create = app.buttons["laa.studio.new"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
        let title = app.textFields["laa.studio.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap(); title.typeText("New presentation")
        let body = app.textViews["laa.studio.composer.field"]
        XCTAssertTrue(body.waitForExistence(timeout: 10)); body.tap(); body.typeText("Make a short overview")
        XCTAssertFalse(app.buttons["laa.studio.composer.textSize"].exists)
        let send = app.buttons["laa.studio.composer.send"]
        if !send.isHittable { app.swipeUp() }
        _ = try helper("mode/create-busy-once")
        XCTAssertTrue(send.waitForExistence(timeout: 10)); XCTAssertGreaterThanOrEqual(send.frame.height, 44); send.tap()
        XCTAssertTrue(app.staticTexts["Studioが使用中です。少し待ってから送り直してください。"].waitForExistence(timeout: 15))
        let retryCreation = app.buttons["laa.studio.retry"]
        XCTAssertTrue(retryCreation.waitForExistence(timeout: 10))
        if !retryCreation.isHittable { app.swipeUp() }
        retryCreation.tap()
        XCTAssertTrue(app.staticTexts["依頼を受け付けました。"].waitForExistence(timeout: 15))
        XCTAssertEqual(try helper("create-consistent"), "true")
    }

    func testV2ReviewRetryAndLibraryThroughMockBridge() throws {
        guard (try? helper("health")) == "ok" else { throw XCTSkip("Start scripts/laa/studio-ui-fixture.mjs first") }
        _ = try helper("reset")
        _ = try helper("mode/v2")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "source", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:19582"
        app.launch()
        XCTAssertTrue(app.buttons["Studio"].waitForExistence(timeout: 30)); app.buttons["Studio"].tap()
        let connect = app.buttons["laa.studio.pair"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10)); connect.tap()
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
        let review = app.buttons["作品への講評"]
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.tap()
        XCTAssertTrue(app.buttons["直す"].waitForExistence(timeout: 10)); app.buttons["直す"].tap()
        let comment = app.textViews["laa.studio.review.comment"]
        XCTAssertTrue(comment.waitForExistence(timeout: 10)); comment.tap(); comment.typeText("Fixture comment")
        let send = app.buttons["laa.studio.review.send"]
        if !send.isHittable { app.swipeUp() }
        _ = try helper("mode/v2-review-lost")
        XCTAssertTrue(send.waitForExistence(timeout: 10)); send.tap()
        let retry = app.buttons["laa.studio.review.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20))
        if !retry.isHittable { app.swipeUp() }
        retry.tap()
        XCTAssertTrue(app.staticTexts["講評を保存しました。"].waitForExistence(timeout: 20))
        XCTAssertEqual(try helper("review-count"), "1")
        XCTAssertEqual(try helper("review-consistent"), "true")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let library = app.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10)); library.tap()
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

    func testV2VideoWithoutMetadataAndDisplacedReviewDraft() throws {
        guard (try? helper("health")) == "ok" else { throw XCTSkip("Start scripts/laa/studio-ui-fixture.mjs first") }
        _ = try helper("reset"); _ = try helper("mode/v2")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "source", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:19582"
        app.launch()
        XCTAssertTrue(app.buttons["Studio"].waitForExistence(timeout: 30)); app.buttons["Studio"].tap()
        XCTAssertTrue(app.buttons["laa.studio.pair"].waitForExistence(timeout: 10)); app.buttons["laa.studio.pair"].tap()
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10)); code.tap(); code.typeText("TEST-TEST")
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        pair.tap()
        let work = app.buttons["laa.studio.work.70175325-5cf4-421f-8a6f-95beae8fca92"]
        XCTAssertTrue(work.waitForExistence(timeout: 30)); work.tap()
        let video = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Example.mp4")).firstMatch
        for _ in 0..<4 where !video.exists { app.swipeUp() }
        XCTAssertTrue(video.waitForExistence(timeout: 10)); XCTAssertTrue(video.label.contains("Video"))
        XCTAssertFalse(video.label.contains("00:")) // The fixture has no duration.
        let preparing = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Preparing.mp4")).firstMatch
        if !preparing.isHittable { app.swipeUp() }
        XCTAssertTrue(preparing.waitForExistence(timeout: 10))
        XCTAssertTrue(preparing.label.contains("閲覧用コピーを準備中"))
        let workScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        workScreenshot.name = "Studio versions - preparing and no poster"
        workScreenshot.lifetime = .keepAlways
        add(workScreenshot)
        preparing.tap()
        XCTAssertTrue(app.staticTexts["閲覧用コピーを準備中です。時間をおいて作品を更新してください。"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let image = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Example.png")).firstMatch
        if !image.isHittable { app.swipeUp() }
        XCTAssertTrue(image.waitForExistence(timeout: 10)); image.tap()
        let review = app.buttons["この版への講評"]
        if !review.isHittable { app.swipeUp() }
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.tap()
        let comment = app.textViews["laa.studio.review.comment"]
        XCTAssertTrue(comment.waitForExistence(timeout: 10)); comment.tap(); comment.typeText("Original version note")
        _ = try helper("mode/v2-rotated")
        let send = app.buttons["laa.studio.review.send"]
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.waitForExistence(timeout: 10)); send.tap()
        XCTAssertTrue(app.staticTexts["講評の対象が見つかりません。作品を更新してください。"].waitForExistence(timeout: 20))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let displaced = app.buttons["laa.studio.displaced.\(String(repeating: "a", count: 64))"]
        for _ in 0..<4 where !displaced.exists { app.swipeUp() }
        XCTAssertTrue(displaced.waitForExistence(timeout: 20)); displaced.tap()
        XCTAssertTrue(app.staticTexts["この版は取得した最新50件にありません。下書きの対象は元の版のままです。別の版への講評には内容をコピーしてください。"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews["laa.studio.review.comment"].value as? String, "Original version note")
        XCTAssertTrue(app.buttons["コメントをコピー"].exists)
        let retry = app.buttons["laa.studio.review.retry"]
        if !retry.isHittable { app.swipeUp() }
        XCTAssertTrue(retry.waitForExistence(timeout: 10)); retry.tap()
        XCTAssertTrue(app.buttons["入力し直す"].waitForExistence(timeout: 20))
    }

    func testDocumentShowsLoadingWhileDriveRetrievesIt() throws {
        guard (try? helper("health")) == "ok" else { throw XCTSkip("Start scripts/laa/studio-ui-fixture.mjs first") }
        _ = try helper("reset"); _ = try helper("mode/v2-document-wait")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "source", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:19582"
        app.launch()
        XCTAssertTrue(app.buttons["Studio"].waitForExistence(timeout: 30)); app.buttons["Studio"].tap()
        XCTAssertTrue(app.buttons["laa.studio.pair"].waitForExistence(timeout: 10)); app.buttons["laa.studio.pair"].tap()
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10)); code.tap(); code.typeText("TEST-TEST")
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        pair.tap()
        let library = app.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 30)); library.tap()
        let document = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sample document")).firstMatch
        if !document.isHittable { app.swipeUp() }
        XCTAssertTrue(document.waitForExistence(timeout: 10)); document.tap()
        let loading = app.descendants(matching: .any).matching(identifier: "laa.studio.document.loading").firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 3))
        XCTAssertTrue(loading.label.contains("資料を読み込んでいます"))
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
