import XCTest
@testable import Conduit

final class LAAWorkDesktopTests: XCTestCase {
    func testKeyboardSelectionStopsAtBothEnds() {
        XCTAssertEqual(LAAWorkDesktopList.next(current: nil, count: 3, delta: 1), 0)
        XCTAssertEqual(LAAWorkDesktopList.next(current: nil, count: 3, delta: -1), 2)
        XCTAssertEqual(LAAWorkDesktopList.next(current: 1, count: 3, delta: 1), 2)
        XCTAssertEqual(LAAWorkDesktopList.next(current: 2, count: 3, delta: 1), 2)
        XCTAssertEqual(LAAWorkDesktopList.next(current: 0, count: 3, delta: -1), 0)
        XCTAssertNil(LAAWorkDesktopList.next(current: nil, count: 0, delta: 1))
    }

    func testSearchMatchesTitlesAndIgnoresBlankQueries() {
        XCTAssertTrue(LAAWorkDesktopList.matches("Review the launch brief", query: ""))
        XCTAssertTrue(LAAWorkDesktopList.matches("Review the launch brief", query: "LAUNCH"))
        XCTAssertTrue(LAAWorkDesktopList.matches("日本語の題名", query: "題名"))
        XCTAssertFalse(LAAWorkDesktopList.matches("Review the launch brief", query: "invoice"))
    }
}
