#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAAMacConnectionStateTests: XCTestCase {
    func testPairingAndReachabilityAreSeparate() {
        XCTAssertEqual(LAAMacConnectionState.current(session: .unpaired, probe: .connected), .notPaired)
        XCTAssertEqual(LAAMacConnectionState.current(session: .keychainError, probe: .connected), .keychainError)
        XCTAssertEqual(LAAMacConnectionState.current(session: .revoked, probe: .connected), .rePairRequired)
        XCTAssertEqual(LAAMacConnectionState.current(session: .unauthorized, probe: .connected), .rePairRequired)
        XCTAssertEqual(LAAMacConnectionState.current(session: .paired, probe: .checking), .checking)
        XCTAssertEqual(LAAMacConnectionState.current(session: .paired, probe: .connected), .connected)
        XCTAssertEqual(LAAMacConnectionState.current(session: .paired, probe: .offline), .offline)
        XCTAssertEqual(LAAMacConnectionState.current(session: .paired, probe: .failed), .failed)
    }

    func testStatusLabelsDescribeTheCurrentState() {
        XCTAssertEqual(LAAMacConnectionState.connected.label, "接続済み")
        XCTAssertEqual(LAAMacConnectionState.offline.label, "未接続")
        XCTAssertEqual(LAAMacConnectionState.notPaired.label, "未接続")
        XCTAssertEqual(LAAMacConnectionState.keychainError.label, "Keychain error")
    }
}
#endif
