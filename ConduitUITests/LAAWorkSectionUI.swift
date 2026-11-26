#if LAA_BUILD
import XCTest

enum LAAWorkSectionUI {
    static func open(_ section: String, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        let destination = app.buttons["work.section.\(section)"]
        if section == "campaigns" && !destination.isHittable {
            let overflow = app.buttons["work.section.more"]
            guard overflow.waitForExistence(timeout: 10) else {
                XCTFail("Work overflow is unavailable", file: file, line: line)
                return
            }
            overflow.tap()
        }
        guard destination.waitForExistence(timeout: 10) else {
            XCTFail("Work section \(section) is unavailable", file: file, line: line)
            return
        }
        destination.tap()
    }
}
#endif
