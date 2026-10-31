#if LAA_BUILD && DEBUG
import XCTest
@testable import Conduit

final class LAABrainSaveTests: XCTestCase {
    func testSaveAndRecoveryFixture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brain-save-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try BrainSaveFixture.selftest(root)
    }
}
#endif
