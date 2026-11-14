#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor
final class LAAWorkContinuationTests: XCTestCase {
    func testSwitchSubsetLeavesTheLaunchCatalogAndAutomaticDefaultIntact() throws {
        let json = #"{"profiles":[{"id":"opus-high","label":"Opus","provider":"claude","model":"opus","effort":"high","fast":true},{"id":"other-high","label":"Other","provider":"codex","model":"other","effort":"high","fast":true}],"switchProfiles":[{"id":"opus-high","label":"Opus","provider":"claude","model":"opus","effort":"high","fast":true}],"defaultProfile":"other-high","defaultMode":"bypass"}"#
        let options = try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.profiles.count, 2)
        XCTAssertEqual(options.switchingOptions.profiles.map(\.id), ["opus-high"])
        XCTAssertEqual(options.switchingOptions.defaultProfile, "other-high")
        XCTAssertEqual(options.defaultMode, "bypass")
    }

    func testOwnerProviderChoiceIsComparedWithTheRuntimeRatherThanTheOriginalProvider() throws {
        let json = #"{"id":"s","name":"same","requestId":"r","profile":"opus-high","phase":"awaiting_review","requested":{"provider":"claude","model":"opus","effort":"high"},"observed":{"provider":"codex","model":"sol","effort":"high"},"ownerChanged":{"provider":"codex","model":"sol","effort":"high"},"capabilities":{"model":true,"providerSwitch":true}}"#
        let row = try JSONDecoder().decode(LAAWorkSession.self, from: Data(json.utf8))
        XCTAssertFalse(row.modelMismatch)
        XCTAssertEqual(row.capabilities?.providerSwitch, true)
        XCTAssertNil(row.modelSwitch)
    }

    func testProjectDefaultDraftKeepsTheDifferenceBetweenUnchangedAndCleared() throws {
        let untouched = LAAWorkProjectChanges(name: "same", instructions: nil)
        let clear = LAAWorkProjectChanges(name: "same", instructions: nil, changesDefaultProfile: true)
        let selected = LAAWorkProjectChanges(name: "same", instructions: nil, defaultProfile: "sol-high", changesDefaultProfile: true)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        func object(_ change: LAAWorkProjectChanges) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(change)) as? [String: Any])
        }
        XCTAssertNil(try object(untouched)["defaultProfile"])
        XCTAssertTrue(try object(clear)["defaultProfile"] is NSNull)
        XCTAssertEqual(try object(selected)["defaultProfile"] as? String, "sol-high")
        let restored = try decoder.decode(LAAWorkProjectChanges.self, from: encoder.encode(clear))
        XCTAssertTrue(restored.changesDefaultProfile)
        XCTAssertNil(restored.defaultProfile)
        let legacy = try decoder.decode(LAAWorkProjectChanges.self, from: Data(#"{"name":"same"}"#.utf8))
        XCTAssertFalse(legacy.changesDefaultProfile)
    }

    func testOlderBridgeDoesNotAdvertiseProjectDefaultEditing() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(LAAWorkProject.self, from: Data(#"{"id":"p","name":"same"}"#.utf8))
        let current = try decoder.decode(LAAWorkProject.self, from: Data(#"{"id":"p","name":"same","defaultProfile":"sol-high"}"#.utf8))
        XCTAssertFalse(old.hasDefaultProfile)
        XCTAssertTrue(current.hasDefaultProfile)
        XCTAssertEqual(current.defaultProfile, "sol-high")
    }
}
#endif
