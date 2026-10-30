#if LAA_BUILD
import XCTest

final class LAAAssetsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ mode: String? = nil, appearance: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "source", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        if let mode { app.launchArguments += ["-laa-assets-fixture", mode] }
        if let appearance { app.launchArguments += ["-conduit.themePreference", appearance] }
        app.launch()
        return app
    }

    private func capture(_ screen: String, _ appearance: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "drive-\(screen)-\(appearance)-iphone16promax"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOwnerDeviceScreenshots() {
        for appearance in ["light", "dark"] {
            let app = launch("normal", appearance: appearance)
            XCTAssertTrue(app.buttons["laa.assets.item.folder1"].waitForExistence(timeout: 30))
            capture("assets", appearance)

            app.swipeUp()
            let video = app.buttons["laa.assets.item.video1"]
            XCTAssertTrue(video.waitForExistence(timeout: 10))
            video.tap()
            let open = app.buttons["laa.drive.open"]
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            capture("details", appearance)
            open.tap()
            XCTAssertTrue(app.buttons["laa.drive.play"].waitForExistence(timeout: 10))
            capture("player", appearance)
            app.terminate()

            for (item, screen, title) in [("image1", "image", "Portrait"), ("doc1", "pdf", "Notes")] {
                let previewApp = launch("normal", appearance: appearance)
                let file = previewApp.buttons["laa.assets.item.\(item)"]
                XCTAssertTrue(file.waitForExistence(timeout: 30))
                file.tap()
                let preview = previewApp.buttons["laa.drive.open"]
                XCTAssertTrue(preview.waitForExistence(timeout: 10))
                preview.tap()
                XCTAssertTrue(previewApp.navigationBars[title].waitForExistence(timeout: 10))
                Thread.sleep(forTimeInterval: 1)
                XCTAssertFalse(previewApp.staticTexts["This file could not be displayed. Open on Mac."].exists)
                capture(screen, appearance)
                previewApp.terminate()
            }
        }
    }

    func testDriveGridFolderSearchAndUnsupportedActions() {
        let app = launch("normal")
        let folder = app.buttons["laa.assets.item.folder1"]
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        XCTAssertTrue(folder.isEnabled)
        XCTAssertFalse(app.buttons["Inspiration"].isEnabled)
        XCTAssertFalse(app.buttons["Studio"].isEnabled)
        XCTAssertTrue(app.staticTexts["Inspiration and Studio are not available yet."].exists)
        XCTAssertTrue(app.buttons["laa.assets.item.image1"].isEnabled)
        folder.tap()
        XCTAssertTrue(app.buttons["laa.assets.item.doc2"].waitForExistence(timeout: 10))
        app.buttons["laa.assets.back"].tap()
        let filter = app.buttons["laa.assets.filter"]
        filter.tap()
        app.buttons["Images"].tap()
        XCTAssertTrue(app.buttons["laa.assets.item.image1"].waitForExistence(timeout: 10))
        XCTAssertFalse(folder.exists)
        XCTAssertTrue(app.staticTexts["Filters apply to loaded items."].exists)
        filter.tap()
        app.buttons["All"].tap()
        let search = app.textFields["laa.assets.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Notes\n")
        XCTAssertTrue(app.buttons["laa.assets.item.doc1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["laa.assets.item.folder1"].exists)
    }

    func testBrowsePlaySeekAndBack() {
        let app = launch("normal")
        app.swipeUp()
        let video = app.buttons["laa.assets.item.video1"]
        XCTAssertTrue(video.waitForExistence(timeout: 30))
        video.tap()
        let open = app.buttons["laa.drive.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let play = app.buttons["laa.drive.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let slider = app.sliders["laa.drive.seek"]
        let enabled = NSPredicate(format: "enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: slider)], timeout: 20), .completed)
        slider.adjust(toNormalizedSliderPosition: 0.5)
        app.buttons["BackButton"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["laa.assets.item.video1"].waitForExistence(timeout: 10))
    }

    func testWorkspaceExplainsUnsupportedExport() {
        let app = launch("normal")
        app.swipeUp()
        let document = app.buttons["laa.assets.item.workspace1"]
        XCTAssertTrue(document.waitForExistence(timeout: 30))
        document.tap()
        XCTAssertTrue(app.staticTexts["Google documents cannot be exported by this Bridge yet. Open on Mac."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Open"].isEnabled)
    }

    func testDrivePagination() {
        let app = launch("paged")
        let more = app.buttons["laa.assets.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        app.swipeUp()
        more.tap()
        XCTAssertTrue(app.buttons["laa.assets.item.image1"].waitForExistence(timeout: 10))
        XCTAssertFalse(more.exists)
    }

    func testEmptyUnconfiguredOfflineAndUnpaired() {
        let empty = launch("empty")
        XCTAssertTrue(empty.staticTexts["No items found."].waitForExistence(timeout: 30))
        empty.terminate()
        let unconfigured = launch("unconfigured")
        XCTAssertTrue(unconfigured.staticTexts["Drive authorization is not configured on the Mac."].waitForExistence(timeout: 30))
        unconfigured.terminate()
        let scopeDenied = launch("scopeDenied")
        XCTAssertTrue(scopeDenied.staticTexts["This device needs the media:read permission."].waitForExistence(timeout: 30))
        scopeDenied.terminate()
        let offline = launch("offline")
        XCTAssertTrue(offline.staticTexts["Macに届きません。TailscaleとMacの接続を確認してください。"].waitForExistence(timeout: 30))
        offline.terminate()
        let error = launch("error")
        XCTAssertTrue(error.staticTexts["Macからデータを取得できませんでした。"].waitForExistence(timeout: 30))
        error.terminate()
        let unpaired = launch()
        XCTAssertTrue(unpaired.buttons["laa.assets.pair"].waitForExistence(timeout: 30))
    }
}
#endif
