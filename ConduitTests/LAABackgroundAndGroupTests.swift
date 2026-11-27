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

    private func key(_ conversation: String = "one", profile: String = "laa-monet", surface: LAABackgroundKey.Surface = .chat,
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

    func testBubblesFollowTheBackgroundUntilChosenAndTheChoiceIsScoped() throws {
        let store = LAABackgroundStore(directory: directory)
        XCTAssertEqual(store.setting(for: key()).bubble, .standard)
        XCTAssertNil(store.setting(for: key()).bubbleChoice)
        try store.save(LAABackground(kind: .paper, bubbleChoice: .glass), for: key())
        XCTAssertEqual(LAABackgroundStore(directory: directory).setting(for: key()).bubble, .glass)
        XCTAssertEqual(store.setting(for: key("two")).bubble, .standard)
        XCTAssertEqual(store.setting(for: key(profile: "laa-cto")).bubble, .standard)
        // A photo chosen afterwards keeps the choice, and so does its loss.
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }.pngData()!
        try store.savePhoto(photo, for: key(), dim: 0, blur: 0)
        let saved = store.setting(for: key())
        XCTAssertEqual(saved.kind, .photo)
        XCTAssertEqual(saved.bubble, .glass)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(try XCTUnwrap(saved.photoID) + ".jpg"))
        XCTAssertEqual(store.setting(for: key()).kind, .paper)
        XCTAssertEqual(store.setting(for: key()).bubble, .glass)

        // With no choice a picture brings the glass and paper takes it away;
        // the owner's "いまの見た目" over a picture stays.
        try store.savePhoto(photo, for: key("three"), dim: 0, blur: 0)
        XCTAssertEqual(store.setting(for: key("three")).bubble, .glass)
        try store.save(LAABackground(kind: .ink), for: key("three"))
        XCTAssertEqual(store.setting(for: key("three")).bubble, .standard)
        try store.save(LAABackground(kind: .paper, bubbleChoice: .standard), for: key("four"))
        try store.savePhoto(photo, for: key("four"), dim: 0, blur: 0)
        XCTAssertEqual(store.setting(for: key("four")).kind, .photo)
        XCTAssertEqual(store.setting(for: key("four")).bubble, .standard)
    }

    func testRecordsSavedBeforeTheChoiceFollowTheBackground() throws {
        let old = #"{"kind":"tealNight","dim":0,"blur":0,"brightestComponent":1}"#
        XCTAssertEqual(try JSONDecoder().decode(LAABackground.self, from: Data(old.utf8)),
                       LAABackground(kind: .tealNight))
        // 2611151632 wrote "bubble" on every save: its "standard" over a
        // picture is not a choice and becomes glass, its "glass" stays.
        let firstBuildPhoto = #"{"kind":"photo","dim":0,"blur":0,"brightestComponent":1,"bubble":"standard"}"#
        let decoded = try JSONDecoder().decode(LAABackground.self, from: Data(firstBuildPhoto.utf8))
        XCTAssertNil(decoded.bubbleChoice)
        XCTAssertEqual(decoded.bubble, .glass)
        let firstBuildGlass = #"{"kind":"paper","dim":0,"blur":0,"brightestComponent":1,"bubble":"glass"}"#
        XCTAssertEqual(try JSONDecoder().decode(LAABackground.self, from: Data(firstBuildGlass.utf8)).bubbleChoice, .glass)
        let unknown = #"{"kind":"ink","dim":0,"blur":0,"brightestComponent":1,"bubbleChoice":"frosted"}"#
        XCTAssertNil(try JSONDecoder().decode(LAABackground.self, from: Data(unknown.utf8)).bubbleChoice)
        for choice in [LAABackground.Bubble.standard, .glass] {
            let value = LAABackground(kind: .photo, bubbleChoice: choice)
            XCTAssertEqual(try JSONDecoder().decode(LAABackground.self, from: JSONEncoder().encode(value)), value)
        }
    }

    /// The bubbles' glass lets the background through: light tints over
    /// the dark backgrounds, denser ones on the paper (owner, 2026-11-16).
    func testGlassTintsLetTheBackgroundThrough() {
        XCTAssertLessThan(LAABubbleGlass.replyTintDark, 0.5)
        XCTAssertLessThan(LAABubbleGlass.ownTintDark, 0.8)
        XCTAssertLessThan(LAABubbleGlass.ownTintLight, 1)
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
        XCTAssertEqual(saved.brightestComponent, 1.0, accuracy: 0.00001)
        XCTAssertLessThanOrEqual(try XCTUnwrap(reopened.image(for: key())).size.width, 1600)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(try XCTUnwrap(saved.photoID) + ".jpg"))
        XCTAssertEqual(reopened.setting(for: key()).kind, .paper)
    }

    func testReplacingAndResettingPhotosKeepsSharedReferences() throws {
        let store = LAABackgroundStore(directory: directory)
        let first = key("first"), second = key("second", surface: .group)
        let white = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
        }.pngData()!
        let red = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
        }.pngData()!
        try store.savePhoto(white, for: first, dim: 0, blur: 0)
        let whiteID = try XCTUnwrap(store.setting(for: first).photoID)
        let whiteURL = directory.appendingPathComponent(whiteID + ".jpg")
        try store.savePhoto(white, for: second, dim: 0, blur: 0)
        XCTAssertEqual(store.setting(for: second).photoID, whiteID)
        try store.save(LAABackground(kind: .paper, photoID: whiteID), for: first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: whiteURL.path))
        XCTAssertNil(store.setting(for: first).photoID)
        try store.savePhoto(red, for: second, dim: 0, blur: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: whiteURL.path))
        let redID = try XCTUnwrap(store.setting(for: second).photoID)
        let redURL = directory.appendingPathComponent(redID + ".jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: redURL.path))
        try store.save(LAABackground(kind: .ink), for: second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: redURL.path))
    }

    func testRemovingDashboardKeepsOtherDashboardAndExcludesBackup() throws {
        let store = LAABackgroundStore(directory: directory)
        let other = UUID()
        let first = key("first"), second = key("second", surface: .group, dashboard: other)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }.pngData()!
        try store.savePhoto(image, for: first, dim: 0, blur: 0)
        try store.savePhoto(image, for: second, dim: 0, blur: 0)
        let photoID = try XCTUnwrap(store.setting(for: first).photoID)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try store.removeAll(dashboardID: dashboard)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(first.fileID + ".json").path))
        XCTAssertEqual(store.setting(for: second).kind, .photo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(photoID + ".jpg").path))
        try store.removeAll(dashboardID: other)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(photoID + ".jpg").path))
    }

    func testAppStateRemovingDashboardRemovesOnlyItsBackgrounds() throws {
        let one = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://background-one.invalid")
        let two = SavedDashboard(id: UUID(), label: "Two", normalizedURL: "https://background-two.invalid")
        let first = key("one", dashboard: one.id), second = key("two", dashboard: two.id)
        let store = LAABackgroundStore.shared
        defer { try? store.removeAll(dashboardID: one.id); try? store.removeAll(dashboardID: two.id) }
        let white = UIGraphicsImageRenderer(size: CGSize(width: 29, height: 23)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 29, height: 23))
        }
        let red = UIGraphicsImageRenderer(size: CGSize(width: 29, height: 23)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 29, height: 23))
        }
        try store.savePhoto(XCTUnwrap(white.pngData()), for: first, dim: 0, blur: 0)
        try store.savePhoto(XCTUnwrap(red.pngData()), for: second, dim: 0, blur: 0)
        let removedPhotoID = try XCTUnwrap(store.setting(for: second).photoID)
        let photoURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LAAConversationBackgrounds", isDirectory: true)
            .appendingPathComponent(removedPhotoID + ".jpg")
        let suite = "LAABackgroundDashboardTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults, loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: one.id, dashboards: [one, two]),
            clearSessionPresentationCache: {})
        state.removeDashboard(two.id)
        XCTAssertEqual(store.setting(for: second).kind, .paper)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photoURL.path))
        XCTAssertEqual(store.setting(for: first).kind, .photo)
        XCTAssertNotNil(store.image(for: first))
    }

    func testCorruptRecordsPreventDeletingUnknownReferences() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LAABackgroundStore(directory: directory)
        let photoID = String(repeating: "a", count: 64)
        let photo = directory.appendingPathComponent(photoID + ".jpg")
        try Data([1]).write(to: photo)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("unknown.json"))
        try store.save(LAABackground(kind: .paper), for: key())
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
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

    func testMemberSelectionAcceptsAllSevenCompanySeatsAndCapsTheRoster() {
        let companySeats = Set(["monet", "cto", "cfo", "cos", "cio", "argus", "cso"].map { "laa-\($0)" })
        XCTAssertEqual(Set(LAAGroupCandidates.all.map { "laa-\($0.rawValue)" }), companySeats)
        var selection = LAAGroupSelection(available: companySeats.union(["overflow"]))
        selection.toggle("not-an-employee")
        XCTAssertTrue(selection.selected.isEmpty)
        selection.toggle("laa-monet")
        XCTAssertFalse(selection.canCreate(name: "Group"))
        selection.toggle("laa-cto")
        XCTAssertTrue(selection.canCreate(name: "Group"))
        XCTAssertFalse(selection.canCreate(name: "  "))
        selection.toggle("laa-monet")
        XCTAssertFalse(selection.selected.contains("laa-monet"))
        for seat in companySeats.subtracting(selection.selected) { selection.toggle(seat) }
        XCTAssertTrue(selection.canCreate(name: "All hands"))
        selection.toggle("overflow")
        XCTAssertEqual(selection.selected, companySeats)
    }

    func testEditedCreateInputsMintANewIdButRetryKeepsIt() {
        let first = GroupCreateAttempt.Inputs(name: "One", members: ["laa-monet", "laa-cfo"])
        let edited = GroupCreateAttempt.Inputs(name: "One", members: ["laa-monet", "laa-cto"])
        let id = GroupCreateAttempt.mintRoomID()
        XCTAssertEqual(GroupCreateAttempt.roomID(for: first, current: id, attempted: first), id)
        XCTAssertNotEqual(GroupCreateAttempt.roomID(for: edited, current: id, attempted: first), id)
    }
}
#endif
