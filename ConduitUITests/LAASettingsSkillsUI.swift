#if LAA_BUILD
import XCTest

/// The Settings sheet opens at the top, with the Skills link partly clipped
/// on the phone. XCTest may report that link hittable while its tap falls
/// below the sheet; scroll the sheet until the whole link is in view.
enum LAASettingsSkillsUI {
    static func open(in app: XCUIApplication) {
        app.openLAASettings()
        let scroller = app.scrollViews.containing(.button, identifier: "settings.skills").firstMatch
        XCTAssertTrue(scroller.waitForExistence(timeout: 10), "Settings must present the scroll view that contains Skills")
        let skills = scroller.buttons["settings.skills"]
        XCTAssertTrue(skills.waitForExistence(timeout: 10))
        for _ in 0..<4 {
            if skills.isHittable && skills.frame.maxY <= scroller.frame.maxY - 24 { break }
            scroller.swipeUp()
        }
        XCTAssertTrue(skills.isHittable && skills.frame.maxY <= scroller.frame.maxY - 24, skills.debugDescription)
        skills.tap()
    }
}
#endif
