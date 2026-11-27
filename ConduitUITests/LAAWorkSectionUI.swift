#if LAA_BUILD
import XCTest

enum LAAWorkSectionUI {
    static func open(_ section: String, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        let destination = app.buttons["work.section.\(section == "campaigns" ? "decisions" : section)"]
        guard destination.waitForExistence(timeout: 10) else {
            XCTFail("Work section \(section) is unavailable", file: file, line: line)
            return
        }
        destination.tap()
        guard section == "campaigns" else { return }
        let picker = app.buttons["work.decisions.sections"]
        guard picker.waitForExistence(timeout: 5) else {
            XCTFail("Decisions dropdown is unavailable", file: file, line: line)
            return
        }
        if picker.label != "Campaigns" {
            picker.tap()
            app.buttons["Campaigns"].firstMatch.tap()
        }
    }
}
#endif
