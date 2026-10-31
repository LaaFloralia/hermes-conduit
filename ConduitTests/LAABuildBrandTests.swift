#if LAA_BUILD
import XCTest
@testable import Conduit

/// The LAA build's own contract: what it calls itself, and the one-time
/// migration away from the upstream alternate icon (BUS-330).
final class LAABuildBrandTests: XCTestCase {
    func testPairingCodeIsTrimmedBeforeItReachesTheBridge() {
        XCTAssertEqual(LAAPairingView.normalizedCode(" 123456\n"), "123456")
        XCTAssertEqual(LAAPairingView.normalizedCode("\tABC123 "), "ABC123")
        XCTAssertEqual(LAAPairingView.normalizedCode("   "), "")
        XCTAssertEqual(LAAPairingView.normalizedCode("123456"), "123456")
    }

    @MainActor
    func testAnInheritedAlternateAppIconIsResetAtLaunch() {
        var resets: [String?] = []
        let choice = AppState.startupAppIconChoice(alternateIconName: "Light") { resets.append($0) }
        XCTAssertEqual(choice, .dark)
        XCTAssertEqual(resets, [nil])
    }

    @MainActor
    func testNoAlternateAppIconNeedsNoReset() {
        var resets = 0
        let choice = AppState.startupAppIconChoice(alternateIconName: nil) { _ in resets += 1 }
        XCTAssertEqual(choice, .dark)
        XCTAssertEqual(resets, 0)
    }

    func testTheBuildNamesItselfInTextForTheModel() {
        XCTAssertEqual(LAAProductBrand.appName, "LAA")
        XCTAssertEqual(LAAProductBrand.display("Open Conduit"), "Open LAA")
        XCTAssertEqual(LAAProductBrand.display("Open LAA"), "Open LAA")
        XCTAssertEqual(LAAProductBrand.display("the Conduit plugin"), "the Hermes plugin")
    }

    func testTheRedactedApprovalKeepsTheNotifiersTextAndIsBrandedForDisplay() {
        // Matching a redacted push depends on the notifier's exact sentence.
        XCTAssertEqual(AppState.redactedApprovalPushDescription,
                       "Hermes needs your approval. Open Conduit for details.")
        XCTAssertEqual(LAAProductBrand.display(AppState.redactedApprovalPushDescription),
                       "Hermes needs your approval. Open LAA for details.")
    }
}
#endif
