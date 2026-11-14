import XCTest
@testable import Conduit

final class AppLockPolicyTests: XCTestCase {
    func testBuildDefaultKeepsUpstreamLockAndSuspendsLAALock() {
        #if LAA_BUILD
        XCTAssertFalse(AppLockPolicy.current.isEnabled)
        XCTAssertFalse(BiometricAuth.status.isAvailable)
        #else
        XCTAssertTrue(AppLockPolicy.current.isEnabled)
        #endif
    }

    func testRetainedPreferenceOnlyRequiresUnlockWhenPolicyEnabled() {
        XCTAssertFalse(AppLockPolicy(isEnabled: false).requiresUnlock(savedRequiresFaceID: true))
        XCTAssertFalse(AppLockPolicy(isEnabled: false).requiresUnlock(savedRequiresFaceID: false))
        XCTAssertTrue(AppLockPolicy(isEnabled: true).requiresUnlock(savedRequiresFaceID: true))
        XCTAssertFalse(AppLockPolicy(isEnabled: true).requiresUnlock(savedRequiresFaceID: false))
    }
}
