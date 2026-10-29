#if LAA_BUILD
import XCTest
import UIKit
@testable import Conduit

@MainActor
final class LAABackgroundAndGroupTests: XCTestCase {
    private var directory: URL!
    private let dashboard = UUID(uuidString: "C50C7E30-75D0-41A2-97AB-B7CCFE185932")!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func key(_ conversation: String = "one", profile: String = "laa-ciel", surface: LAABackgroundKey.Surface = .chat,
                     dashboard: UUID? = nil) -> LAABackgroundKey {
        LAABackgroundKey(dashboard: dashboard ?? self.dashboard, profile: profile, conversation: conversation, surface: surface)
    }

    func testStorageIsScopedAndSurvivesNewStore() throws {
        let store = LAABackgroundStore(directory: directory)
        try store.save(LAABackground(kind: .tealNight), for: key())
        try store.save(LAABackground(kind: .ink), for: key(surface: .group))
        try store.save(LAABackground(kind: .tealNight), for: key("two", surface: .group))
        let reopened = LAABackgroundStore(directory: directory)
        XCTAssertEqual(reopened.setting(for: key()).kind, .tealNight)
        XCTAssertEqual(reopened.setting(for: key(surface: .group)).kind, .ink)
        XCTAssertEqual(reopened.setting(for: key("two", surface: .group)).kind, .tealNight)
        XCTAssertEqual(reopened.setting(for: key("three", surface: .group)).kind, .paper)
        XCTAssertEqual(reopened.setting(for: key("two")).kind, .paper)
        XCTAssertEqual(reopened.setting(for: key(profile: "laa-cto")).kind, .paper)
        XCTAssertEqual(reopened.setting(for: key(dashboard: UUID())).kind, .paper)
    }

    func testPhotoIsDownscaledPersistsAndMissingFallsBackToPaper() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2200, height: 1100)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2200, height: 1100))
        }
        let store = LAABackgroundStore(directory: directory)
        try store.savePhoto(XCTUnwrap(image.pngData()), for: key(), dim: 0.2, blur: 12)
        let reopened = LAABackgroundStore(directory: directory)
        let saved = reopened.setting(for: key())
        XCTAssertEqual(saved.kind, .photo)
        XCTAssertEqual(saved.dim, 0.2, accuracy: 0.001)
        XCTAssertEqual(saved.blur, 12, accuracy: 0.001)
        XCTAssertLessThanOrEqual(try XCTUnwrap(reopened.image(for: key())).size.width, 1600)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(try XCTUnwrap(saved.photoID) + ".jpg"))
        XCTAssertEqual(reopened.setting(for: key()).kind, .paper)
    }

    func testContrastDimmingForEveryBrightnessAndClamping() {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        for i in 0...255 {
            let brightest = Double(i) / 255
            let photo = LAABackground(kind: .photo, dim: 0, blur: 0, brightestComponent: brightest)
            let after = brightest * (1 - photo.safeDim)
            let contrast = 1.05 / (linear(after) + 0.05)
            XCTAssertGreaterThanOrEqual(contrast, 4.5 - 0.00001, "brightness \(i)")
            XCTAssertLessThanOrEqual(photo.safeDim, 0.6)
        }
        var value = LAABackground(kind: .photo, dim: 4, blur: -3)
        value.normalize()
        XCTAssertEqual(value.dim, 0.6)
        XCTAssertEqual(value.blur, 0)
    }

    func testMemberSelectionIsLimitedToAvailableEmployeesAndTwoToSix() {
        var selection = LAAGroupSelection(available: Set(LAAWidgetEmployee.allCases.map(\.profile)))
        selection.toggle("not-an-employee")
        XCTAssertTrue(selection.selected.isEmpty)
        selection.toggle("laa-ciel")
        XCTAssertFalse(selection.canCreate(name: "Group"))
        selection.toggle("laa-cto")
        XCTAssertTrue(selection.canCreate(name: "Group"))
        XCTAssertFalse(selection.canCreate(name: "  "))
        selection.toggle("laa-ciel")
        XCTAssertFalse(selection.selected.contains("laa-ciel"))
        for employee in LAAWidgetEmployee.allCases where !selection.selected.contains(employee.profile) { selection.toggle(employee.profile) }
        XCTAssertEqual(selection.selected.count, 6)
    }

    func testEditedCreateInputsMintANewIdButRetryKeepsIt() {
        let first = GroupCreateAttempt.Inputs(name: "One", members: ["laa-ciel", "laa-cfo"])
        let edited = GroupCreateAttempt.Inputs(name: "One", members: ["laa-ciel", "laa-cto"])
        let id = GroupCreateAttempt.mintRoomID()
        XCTAssertEqual(GroupCreateAttempt.roomID(for: first, current: id, attempted: first), id)
        XCTAssertNotEqual(GroupCreateAttempt.roomID(for: edited, current: id, attempted: first), id)
    }
}
#endif
