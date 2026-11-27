#if LAA_BUILD
import Security
import XCTest
@testable import Conduit

/// D-35: the Bridge Keychain service moved from com.laa.conduit.bridge to
/// com.laa.hortensia.bridge, and the pending Brain write with it. A build from
/// before the rename must keep working after a rollback, so both names stay in
/// step until a later release removes the old one.
final class LAAKeychainRenameTests: XCTestCase {
    private func item(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func exists(_ query: [String: Any]) -> Bool {
        SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func add(_ data: Data, to query: [String: Any]) {
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
    }

    private func credentials(_ deviceID: String) -> LAABridgeCredentials {
        LAABridgeCredentials(baseURL: URL(string: "https://mac.tail0000.ts.net")!, deviceID: deviceID, token: "token")
    }

    /// Names only this test run uses: the real pairing and pending write are
    /// never read, changed or removed, whatever state the device is in.
    private let oldService = "com.laa.tests.rename.old." + UUID().uuidString
    private let newService = "com.laa.tests.rename.new." + UUID().uuidString
    private var bridge: LAABridgeKeychain { LAABridgeKeychain(testService: newService, legacy: oldService) }

    private func ownItems(_ account: String) -> (old: [String: Any], new: [String: Any]) {
        let old = item(oldService, account), new = item(newService, account)
        addTeardownBlock { SecItemDelete(old as CFDictionary); SecItemDelete(new as CFDictionary) }
        return (old, new)
    }

    private func emptyBridgeItems() throws -> (old: [String: Any], new: [String: Any]) { ownItems("device") }

    func testBridgePairingUnderTheOldServiceIsReadAndCopiedForward() throws {
        let (old, new) = try emptyBridgeItems()
        add(try JSONEncoder().encode(credentials("dev_rename")), to: old)

        XCTAssertEqual(try bridge.read()?.deviceID, "dev_rename")
        XCTAssertTrue(exists(new), "the pairing is copied to the new service")
        XCTAssertTrue(exists(old), "the old item stays until a later release removes it")
        var attributes = new
        attributes[kSecReturnAttributes as String] = true
        var found: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(attributes as CFDictionary, &found), errSecSuccess)
        XCTAssertEqual((found as? [String: Any])?[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testANewPairingIsAlsoSavedUnderTheOldServiceForARollback() throws {
        let (old, _) = try emptyBridgeItems()
        try bridge.save(credentials("dev_new"))
        let stored = try XCTUnwrap(LAABridgeKeychain.item(old))
        XCTAssertEqual(try JSONDecoder().decode(LAABridgeCredentials.self, from: stored.data).deviceID, "dev_new")
    }

    func testAPairingMadeByAnOlderBuildAfterARollbackWins() throws {
        let (old, _) = try emptyBridgeItems()
        try bridge.save(credentials("dev_before"))
        Thread.sleep(forTimeInterval: 1.1)
        try LAABridgeKeychain.store(try JSONEncoder().encode(credentials("dev_rollback")), old)

        XCTAssertEqual(try bridge.read()?.deviceID, "dev_rollback")
        try bridge.save(credentials("dev_next"))
        XCTAssertEqual(try bridge.read()?.deviceID, "dev_next", "a later save here wins again")
    }

    func testABrokenOldItemDoesNotHideAGoodPairing() throws {
        let (old, new) = try emptyBridgeItems()
        add(try JSONEncoder().encode(credentials("dev_good")), to: new)
        Thread.sleep(forTimeInterval: 1.1)
        add(Data("not json".utf8), to: old)
        XCTAssertEqual(try bridge.read()?.deviceID, "dev_good")
    }

    func testAPendingBrainWriteSurvivesTheRenameAndIsClearedUnderBothNames() throws {
        let (old, new) = ownItems("pending")

        let request = try XCTUnwrap(LAABrainCreateBody.make(name: "rename", content: "body"))
        let key = LAABridgeIdempotencyKey().value
        let pending = LAABrainPending(request: request, bytes: try JSONEncoder().encode(request),
                                      keyValue: key, deviceID: "dev_rename")
        add(try JSONEncoder().encode(pending), to: old)

        let store = LAABrainPendingStore(service: newService, legacy: oldService)
        XCTAssertEqual(try store.read()?.keyValue, key, "the same key, so a retry is not a second write")
        XCTAssertTrue(exists(old), "a rollback still finds it")
        XCTAssertTrue(exists(new))
        try store.clear()
        XCTAssertFalse(exists(old) || exists(new))
        XCTAssertNil(try store.read())

        try store.save(pending)
        XCTAssertTrue(exists(old) && exists(new), "a new pending write is kept under both names")
        try store.clear()
    }
}
#endif
