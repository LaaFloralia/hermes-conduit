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
            XCTAssertTrue(app.buttons["laa.drive.browser.item.folder1"].waitForExistence(timeout: 30))
            capture("assets", appearance)

            app.swipeUp()
            let video = app.buttons["laa.drive.browser.item.video1"]
            XCTAssertTrue(video.waitForExistence(timeout: 10))
            video.tap()
            let open = app.buttons["laa.drive.open"]
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            capture("details", appearance)
            open.tap()
            XCTAssertTrue(app.otherElements["laa.drive.player"].waitForExistence(timeout: 10))
            capture("player", appearance)
            app.terminate()

            for (item, screen, title) in [("image1", "image", "Portrait"), ("doc1", "pdf", "Notes")] {
                let previewApp = launch("normal", appearance: appearance)
                let file = previewApp.buttons["laa.drive.browser.item.\(item)"]
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
        let folder = app.buttons["laa.drive.browser.item.folder1"]
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        XCTAssertTrue(folder.isEnabled)
        XCTAssertFalse(app.buttons["Inspiration"].isEnabled)
        XCTAssertTrue(app.buttons["Studio"].isEnabled)
        XCTAssertTrue(app.buttons["laa.drive.browser.item.image1"].isEnabled)
        folder.tap()
        XCTAssertTrue(app.buttons["laa.drive.browser.item.doc2"].waitForExistence(timeout: 10))
        app.buttons["laa.drive.browser.back"].tap()
        app.buttons["laa.drive.browser.layout"].tap()
        XCTAssertTrue(app.buttons["laa.drive.browser.item.image1"].waitForExistence(timeout: 10))
        app.buttons["laa.drive.browser.section.shared"].tap()
        XCTAssertTrue(app.buttons["laa.drive.browser.section.my"].exists)
        app.buttons["laa.drive.browser.section.my"].tap()
        let search = app.textFields["laa.drive.browser.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Notes\n")
        XCTAssertTrue(app.buttons["laa.drive.browser.item.doc1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["laa.drive.browser.item.folder1"].exists)
    }

    func testBrowsePlaySeekAndBack() {
        let app = launch("normal")
        app.swipeUp()
        let video = app.buttons["laa.drive.browser.item.video1"]
        XCTAssertTrue(video.waitForExistence(timeout: 30))
        video.tap()
        let open = app.buttons["laa.drive.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let surface = app.otherElements["laa.drive.player"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        let play = app.buttons["Play"]
        if !play.exists { surface.tap() }
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 20))
        let slider = app.sliders.firstMatch
        let enabled = NSPredicate(format: "enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: slider)], timeout: 20), .completed)
        slider.adjust(toNormalizedSliderPosition: 0.5)
        app.buttons["BackButton"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["laa.drive.browser.item.video1"].waitForExistence(timeout: 10))
    }

    func testWorkspaceOpensInGoogleDrive() {
        let app = launch("normal")
        app.swipeUp()
        let document = app.buttons["laa.drive.browser.item.workspace1"]
        XCTAssertTrue(document.waitForExistence(timeout: 30))
        document.tap()
        let openInDrive = app.descendants(matching: .any)["laa.drive.open-in-drive"]
        XCTAssertTrue(openInDrive.waitForExistence(timeout: 10))
        XCTAssertTrue(openInDrive.isEnabled)
        XCTAssertFalse(app.buttons["laa.drive.offline.save"].exists)
    }

    func testWorkspaceWithoutLinkExplainsUnavailable() {
        let app = launch("workspaceNoLink")
        app.swipeUp()
        let document = app.buttons["laa.drive.browser.item.workspace1"]
        XCTAssertTrue(document.waitForExistence(timeout: 30))
        document.tap()
        XCTAssertTrue(app.staticTexts["Google Drive link unavailable."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["laa.drive.open-in-drive"].exists)
    }

    func testDrivePagination() {
        let app = launch("paged")
        let more = app.buttons["laa.drive.browser.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        app.swipeUp()
        more.tap()
        XCTAssertTrue(app.buttons["laa.drive.browser.item.image1"].waitForExistence(timeout: 10))
        XCTAssertFalse(more.exists)
    }

    func testFolderSaveShowsEstimateBeforeConfirmation() {
        let app = launch("normal")
        let folder = app.buttons["laa.drive.browser.item.folder1"]
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.press(forDuration: 1)
        let save = app.buttons["Save folder offline"]
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap()
        XCTAssertTrue(app.buttons["Save files"].waitForExistence(timeout: 20))
        let message = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Existing saved copies are kept if saving fails.")).firstMatch
        XCTAssertTrue(message.exists)
        app.buttons["Cancel"].tap()
    }

    func testEmptyUnconfiguredOfflineAndUnpaired() {
        let empty = launch("empty")
        XCTAssertTrue(empty.staticTexts["No items found."].waitForExistence(timeout: 30))
        empty.terminate()
        let unconfigured = launch("unconfigured")
        XCTAssertTrue(unconfigured.staticTexts["Google Drive for desktop is unavailable on the Mac."].waitForExistence(timeout: 30))
        unconfigured.terminate()
        let scopeDenied = launch("scopeDenied")
        XCTAssertTrue(scopeDenied.staticTexts["This device needs the media:read permission."].waitForExistence(timeout: 30))
        scopeDenied.terminate()
        let offline = launch("offline")
        XCTAssertTrue(offline.staticTexts["Cannot reach the Mac. Check Tailscale and the Mac."].waitForExistence(timeout: 30))
        offline.terminate()
        let error = launch("error")
        XCTAssertTrue(error.staticTexts["Could not get data from the Mac."].waitForExistence(timeout: 30))
        error.terminate()
        let unpaired = launch()
        XCTAssertTrue(unpaired.buttons["laa.assets.pair"].waitForExistence(timeout: 30))
    }
}
#endif
