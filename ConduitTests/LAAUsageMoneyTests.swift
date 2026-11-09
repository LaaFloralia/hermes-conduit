#if LAA_BUILD
import Foundation
import XCTest
@testable import Conduit

final class LAAUsageMoneyTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    func testDollarsKeepCents() {
        XCTAssertEqual(LAAUsageMoney.text(1.567807402, locale: locale), "$1.57")
        XCTAssertEqual(LAAUsageMoney.text(12.3, locale: locale), "$12.30")
        XCTAssertEqual(LAAUsageMoney.text(1_234.5, locale: locale), "$1,234.50")
    }

    func testSmallAmountsKeepTwoSignificantDigitsWithinFourDecimals() {
        XCTAssertEqual(LAAUsageMoney.text(0.567807402, locale: locale), "$0.57")
        XCTAssertEqual(LAAUsageMoney.text(0.0567807402, locale: locale), "$0.057")
        XCTAssertEqual(LAAUsageMoney.text(0.00567807402, locale: locale), "$0.0057")
        XCTAssertEqual(LAAUsageMoney.text(0.000567807402, locale: locale), "$0.0006")
        XCTAssertEqual(LAAUsageMoney.text(0.00004, locale: locale), "<$0.0001")
    }

    func testZeroMissingAndNegativeAmounts() {
        XCTAssertEqual(LAAUsageMoney.text(0, locale: locale), "$0.00")
        XCTAssertEqual(LAAUsageMoney.text(nil, locale: locale), "未取得")
        XCTAssertEqual(LAAUsageMoney.text(Double.nan, locale: locale), "未取得")
        XCTAssertEqual(LAAUsageMoney.text(Double.infinity, locale: locale), "未取得")
        XCTAssertEqual(LAAUsageMoney.text(-1.567, locale: locale), "-$1.57")
    }
}
#endif
