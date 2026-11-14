#if LAA_BUILD && os(iOS) && !targetEnvironment(macCatalyst)
import XCTest
@testable import Conduit

@MainActor
final class LAAPhoneUseTokenTests: XCTestCase {
    func testForegroundRefreshRegistersCurrentTokenAfterEarlierSuccess() async {
        var token = Data([0xab])
        var sent: [String] = []
        let service = LAAPhoneUseService(currentStartToken: { token }, sendStartToken: { value, _ in
            sent.append(value)
            return true
        })
        await service.refreshStartToken()
        token = Data([0xcd])
        await service.refreshStartToken()
        await service.refreshStartToken()
        XCTAssertEqual(sent, ["ab", "cd", "cd"])
    }

    func testFailedRegistrationRetriesWhenAppRunsAgain() async {
        var attempts = 0
        let service = LAAPhoneUseService(currentStartToken: { Data([0xab]) }, sendStartToken: { _, _ in
            attempts += 1
            return attempts > 1
        })
        await service.refreshStartToken()
        XCTAssertEqual(attempts, 1, "a failure must not busy-loop")
        await service.refreshStartToken()
        XCTAssertEqual(attempts, 2)
    }

    func testTemporarilyMissingSnapshotRetainsLastKnownToken() async {
        var token: Data? = Data([0xab])
        var sent: [String] = []
        let service = LAAPhoneUseService(currentStartToken: { token }, sendStartToken: { value, _ in
            sent.append(value)
            return true
        })
        await service.refreshStartToken()
        token = nil
        await service.refreshStartToken()
        XCTAssertEqual(sent, ["ab", "ab"])
    }

    func testNoTokenDoesNotRegister() async {
        var attempts = 0
        let service = LAAPhoneUseService(currentStartToken: { nil }, sendStartToken: { _, _ in
            attempts += 1
            return true
        })
        await service.refreshStartToken()
        XCTAssertEqual(attempts, 0)
    }

    func testTokenRotationWaitsForOlderWriteThenRegistersNewestToken() async {
        var token = Data([0xab])
        var sent: [(String, String?)] = []
        var resumeFirst: CheckedContinuation<Void, Never>?
        let entered = expectation(description: "first registration started")
        let service = LAAPhoneUseService(currentStartToken: { token }, sendStartToken: { value, wake in
            sent.append((value, wake))
            if sent.count == 1 {
                await withCheckedContinuation { continuation in
                    resumeFirst = continuation
                    entered.fulfill()
                }
            }
            return true
        })
        let first = Task { await service.refreshStartToken() }
        await fulfillment(of: [entered], timeout: 2)
        token = Data([0xcd])
        await service.refreshStartToken()
        XCTAssertEqual(sent.map(\.0), ["ab"], "registration writes must not overlap")
        resumeFirst?.resume()
        await first.value
        XCTAssertEqual(sent.map(\.0), ["ab", "cd"])
    }
}
#endif
