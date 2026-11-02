#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor final class LAALinearTaskIntegrationTests: XCTestCase {
    func testTaskDeepLinksRejectOtherRoutesAndExtraArguments() throws {
        let uuid = "d1f71177-5355-4f4f-b42c-7894c0870112"
        XCTAssertEqual(LAALinearTaskRoute.issueID(from: try XCTUnwrap(URL(string: "laa://work/tasks/" + uuid))), uuid)
        XCTAssertEqual(LAALinearTaskRoute.issueID(from: try XCTUnwrap(URL(string: "laa://work/tasks/BUS-339"))), "BUS-339")
        for value in ["https://work/tasks/BUS-339", "laa://work/sessions/BUS-339", "laa://work/tasks/BUS-339?send=1", "laa://work/tasks/BUS-339#edit", "laa://work/tasks/", "laa://work/tasks/BUS-339/extra"] {
            XCTAssertNil(LAALinearTaskRoute.issueID(from: try XCTUnwrap(URL(string: value))))
        }
    }
    func testSessionHintsUseNamesOrBoundedIDsAndDoNotInventState() throws {
        let data = Data(#"{"id":"ses_0123456789abcdef","delegateSessionId":"12345678-abcd-abcd-abcd-123456789012","name":"子｜linear","requestId":"request","workspaceId":"workspace","profile":"fixture","phase":"running","createdAt":"now","updatedAt":"now","events":{"lastSeq":0,"oldestSeq":0,"cursor":"cursor"}}"#.utf8)
        let session = try JSONDecoder().decode(LAAWorkSession.self, from: data)
        XCTAssertTrue(LAATaskSessionReferences.matches(session, text: "担当: 子｜linear"))
        XCTAssertTrue(LAATaskSessionReferences.matches(session, text: "agent ID `12345678-abcd-abcd-abcd-123456789012`"))
        XCTAssertFalse(LAATaskSessionReferences.matches(session, text: "some other issue or agent"))
        XCTAssertFalse(LAATaskSessionReferences.matches(session, text: "prefixses_0123456789abcdefsuffix"))
        XCTAssertEqual(session.phase, "running")
    }
    func testTaskCacheIsDeviceAndFilterScopedAndRestoresImmediately() throws {
        let id = UUID().uuidString
        let snapshot = LAALinearTaskCache.OwnerSnapshot(items: [])
        LAALinearTaskCache.save(snapshot, device: id, scope: "mine")
        let start = Date()
        let restored: LAALinearTaskCache.OwnerSnapshot? = LAALinearTaskCache.read(device: id, scope: "mine")
        XCTAssertNotNil(restored)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let otherDevice: LAALinearTaskCache.OwnerSnapshot? = LAALinearTaskCache.read(device: id + "other", scope: "mine")
        let otherFilter: LAALinearTaskCache.OwnerSnapshot? = LAALinearTaskCache.read(device: id, scope: "archived")
        XCTAssertNil(otherDevice); XCTAssertNil(otherFilter)
    }
}
#endif
