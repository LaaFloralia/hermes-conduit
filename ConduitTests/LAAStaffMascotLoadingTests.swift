#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor
final class LAAStaffMascotLoadingTests: XCTestCase {
    func testFirstDragLoadsContainerOutsideMainThread() async {
        let loaded = expectation(description: "container read on decoder queue")
        let turner = StaffMascotTurner(loadSource: { _ in
            XCTAssertFalse(Thread.isMainThread)
            loaded.fulfill()
            return nil
        })
        turner.drag(by: 20, url: URL(fileURLWithPath: "/synthetic/mascot.heic"))
        XCTAssertTrue(turner.turning)
        await fulfillment(of: [loaded], timeout: 2)
        turner.stop()
    }
}
#endif
