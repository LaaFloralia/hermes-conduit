#if LAA_BUILD
import XCTest

enum LAAWorkSectionUI {
    static func open(_ section: String, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        // All five sections sit in one row (D-21 B); none hides in an overflow menu.
        let destination = app.buttons["work.section.\(section)"]
        guard destination.waitForExistence(timeout: 10) else {
            XCTFail("Work section \(section) is unavailable", file: file, line: line)
            return
        }
        destination.tap()
    }
}
#endif
