#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor
final class LAABridgeRecoveryTests: XCTestCase {
    private let saved = LAABridgeCredentials(baseURL: URL(string: "https://mac.test.ts.net:8445")!,
                                             deviceID: "fixture-device", token: "fixture-token")

    func testLockedKeychainCanRecoverTheExistingDeviceWithoutReenrollment() {
        var reads = 0
        let bridge = LAABridgeSession(readCredentials: {
            reads += 1
            if reads == 1 { throw LAABridgeError.keychain }
            return self.saved
        })
        XCTAssertEqual(bridge.status, .keychainError)
        XCTAssertNil(bridge.deviceID)

        bridge.retryReadingCredentialsIfNeeded()
        XCTAssertEqual(bridge.status, .paired)
        XCTAssertEqual(bridge.deviceID, saved.deviceID)
        XCTAssertEqual(bridge.revision, 1)

        bridge.retryReadingCredentialsIfNeeded()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(bridge.revision, 1)
    }

    func testUnreadableAndMissingItemsRemainDistinctAndCanRecover() {
        var reads = 0
        let bridge = LAABridgeSession(readCredentials: {
            reads += 1
            if reads < 3 { throw LAABridgeError.keychain }
            if reads == 3 { return nil }
            return self.saved
        })
        bridge.retryReadingCredentialsIfNeeded()
        XCTAssertEqual(bridge.status, .keychainError)
        XCTAssertEqual(bridge.revision, 0)
        bridge.retryReadingCredentialsIfNeeded()
        XCTAssertEqual(bridge.status, .unpaired)
        XCTAssertEqual(bridge.revision, 1)
        bridge.retryReadingCredentialsIfNeeded()
        XCTAssertEqual(bridge.status, .paired)
        XCTAssertEqual(bridge.deviceID, saved.deviceID)
        XCTAssertEqual(bridge.revision, 2)
    }

    func testExplicitAuthenticationFailuresAreNeverClearedByLocalRetry() {
        for status in [LAABridgeSession.Status.revoked, .unauthorized, .paired] {
            var reads = 0
            let bridge = LAABridgeSession(statusForTesting: status, readCredentials: {
                reads += 1
                return self.saved
            })
            bridge.retryReadingCredentialsIfNeeded()
            XCTAssertEqual(bridge.status, status)
            XCTAssertEqual(bridge.revision, 0)
            XCTAssertEqual(reads, 0)
        }
    }
}
#endif
