#if LAA_BUILD
import XCTest

final class LAAAssetsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ mode: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "source"]
        if let mode { app.launchArguments += ["-laa-assets-fixture", mode] }
        app.launch()
        return app
    }

    func testDriveGridFolderSearchAndUnsupportedActions() {
        let app = launch("normal")
        let folder = app.buttons["laa.assets.item.folder1"]
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        XCTAssertTrue(folder.isEnabled)
        XCTAssertFalse(app.buttons["Inspiration"].isEnabled)
        XCTAssertFalse(app.buttons["Studio"].isEnabled)
        XCTAssertTrue(app.staticTexts["Inspiration and Studio are not available yet."].exists)
        XCTAssertFalse(app.buttons["laa.assets.item.image1"].isEnabled)
        XCTAssertTrue(app.staticTexts["File previews are not available yet."].exists)
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
        let unpaired = launch()
        XCTAssertTrue(unpaired.buttons["laa.assets.pair"].waitForExistence(timeout: 30))
    }
}
#endif
