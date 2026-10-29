import XCTest

final class LAABackgroundAndGroupUITests: XCTestCase {
    #if LAA_BUILD
    private func openBackground(_ app: XCUIApplication) {
        let menu = app.buttons["conversation.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let choice = app.buttons["conversation.background"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        XCTAssertTrue(app.buttons["background.choice.paper"].waitForExistence(timeout: 5))
    }

    func testAllBackgroundsAndPhotoControlsPersist() {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND"]
        app.launch()
        openBackground(app)
        for kind in ["paper", "tealNight", "ink"] {
            let choice = app.buttons["background.choice.\(kind)"]
            choice.tap()
            XCTAssertEqual(choice.value as? String, "選択中")
        }
        app.buttons["background.fixture.photo"].tap()
        let dim = app.sliders["background.photo.dim"]
        XCTAssertTrue(dim.waitForExistence(timeout: 5))
        dim.adjust(toNormalizedSliderPosition: 0.65)
        let blur = app.sliders["background.photo.blur"]
        blur.adjust(toNormalizedSliderPosition: 0.5)
        let dimValue = dim.value as? String
        let blurValue = blur.value as? String
        XCTAssertNotNil(dimValue)
        XCTAssertNotNil(blurValue)
        app.buttons["完了"].tap()
        app.terminate()
        app.launch()
        openBackground(app)
        XCTAssertTrue(app.sliders["background.photo.dim"].exists)
        XCTAssertTrue(app.sliders["background.photo.blur"].exists)
        XCTAssertEqual(app.sliders["background.photo.dim"].value as? String, dimValue)
        XCTAssertEqual(app.sliders["background.photo.blur"].value as? String, blurValue)
    }

    func testEmptyErrorAndOfflineGroupStates() {
        for (mode, expected) in [
            ("empty", "グループはまだありません。"),
            ("error", "グループを読み込めませんでした"),
            ("offline", "グループを開くには Hermes に接続してください。")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_GROUPS_STATE", mode]
            app.launch()
            let list = app.buttons["fixture.groups.list"]
            XCTAssertTrue(list.waitForExistence(timeout: 20))
            list.tap()
            let label = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 15), mode)
            app.terminate()
        }
    }

    func testUnpairedBridgeExplainsPairingAndRejectsEmptyCode() {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_UI_TEST_REAL_BRIDGE"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.bridge.status"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["fixture.bridge.status"].label, "未接続")
        app.buttons["fixture.bridge"].tap()
        let pair = app.buttons["laa.bridge.pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 5))
        XCTAssertFalse(pair.isEnabled)
    }

    func testCreateAndUnsupportedParticipantChanges() {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND"]
        app.launch()
        // The expanded photo canvas must not intercept controls above it.
        openBackground(app)
        app.buttons["background.fixture.photo"].tap()
        app.buttons["完了"].tap()
        let create = app.buttons["fixture.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 20))
        create.tap()
        let name = app.textFields["groups.create.name"]
        guard name.waitForExistence(timeout: 5) else {
            XCTFail("The group creation screen did not open above the photo background")
            return
        }
        name.tap(); name.typeText("Planning")
        app.buttons["groups.employee.laa-ciel"].tap()
        app.buttons["groups.employee.laa-cto"].tap()
        let submit = app.buttons["groups.create.submit"]
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(app.staticTexts["fixture.created"].waitForExistence(timeout: 5))
        app.buttons["fixture.settings"].tap()
        let add = app.buttons["groups.member.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertFalse(add.isEnabled)
        XCTAssertFalse(app.buttons["groups.member.remove.laa-ciel"].isEnabled)
        XCTAssertTrue(app.staticTexts["この接続先には参加者を追加・削除する機能がありません。"].exists)
        let rename = app.textFields["groups.rename.name"]
        rename.tap()
        rename.typeText("2")
        app.buttons["groups.rename.submit"].tap()
        let created = app.staticTexts["fixture.created"]
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        XCTAssertTrue(created.label.contains("2"))
        app.buttons["fixture.groups.list"].tap()
        let openCreate = app.buttons["groups.create.open"]
        XCTAssertTrue(openCreate.waitForExistence(timeout: 15))
        openCreate.tap()
        XCTAssertTrue(app.textFields["groups.create.name"].waitForExistence(timeout: 5))
    }
    #else
    func testOnlyAvailableInLAABuild() throws { throw XCTSkip("LAA build only") }
    #endif
}
