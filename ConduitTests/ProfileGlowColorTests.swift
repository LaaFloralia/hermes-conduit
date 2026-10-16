//
//  ProfileGlowColorTests.swift
//  Conduit
//
//  The backdrop glow per profile: colors drawn from the photo, the fallback
//  to a photo's second and third color when an earlier profile already
//  glows alike, and the picked color kept per dashboard.
//

import CoreGraphics
import XCTest
@testable import Conduit

/// An extension of an existing class, so the CI test plan gains no class.
extension ProfileModelDefaultsTests {
    private var red: ProfileGlowRGB { ProfileGlowRGB(red: 0.9, green: 0.1, blue: 0.1) }
    private var green: ProfileGlowRGB { ProfileGlowRGB(red: 0.1, green: 0.8, blue: 0.2) }
    private var blue: ProfileGlowRGB { ProfileGlowRGB(red: 0.1, green: 0.2, blue: 0.9) }

    // MARK: Palette

    func testMainColorIsTheOneCoveringMostOfThePhoto() throws {
        let image = try makeGlowImage(bands: [(red, 0.7), (blue, 0.3)])
        let colors = ProfileGlowPalette.colors(from: image)
        // `guard` so a short palette fails cleanly instead of trapping.
        guard colors.count == 2 else { return XCTFail("Expected 2 colors, got \(colors)") }
        XCTAssertTrue(colors[0].looksLike(red))
        XCTAssertTrue(colors[1].looksLike(blue))
    }

    func testGreyPhotoHasNoGlowColor() throws {
        let grey = ProfileGlowRGB(red: 0.5, green: 0.5, blue: 0.5)
        let black = ProfileGlowRGB(red: 0.02, green: 0.02, blue: 0.02)
        let image = try makeGlowImage(bands: [(grey, 0.5), (black, 0.5)])
        XCTAssertEqual(ProfileGlowPalette.colors(from: image), [])
    }

    func testStrayPixelsNeverBecomeAColor() throws {
        let image = try makeGlowImage(bands: [(red, 0.98), (blue, 0.02)])
        let colors = ProfileGlowPalette.colors(from: image)
        guard colors.count == 1 else { return XCTFail("Expected 1 color, got \(colors)") }
        XCTAssertTrue(colors[0].looksLike(red))
    }

    func testDarkPhotoColorIsLiftedToAGlow() {
        let dark = ProfileGlowRGB(red: 0.3, green: 0.05, blue: 0.05)
        let glow = ProfileGlowPalette.glowable(dark)
        XCTAssertGreaterThanOrEqual(glow.hsb.brightness, 0.74)
        XCTAssertTrue(glow.looksLike(dark))
    }

    // MARK: Assignment

    func testSecondProfileWithTheSameMainColorFallsBackToItsSecondColor() {
        let colors = ProfileGlowAssignment.assign(
            order: ["default", "work"],
            palettes: ["default": [red, blue], "work": [red, green, blue]],
            picked: [:]
        )
        XCTAssertEqual(colors["default"], red)
        XCTAssertEqual(colors["work"], green)
    }

    func testThirdColorWhenTheSecondIsTakenToo() {
        let colors = ProfileGlowAssignment.assign(
            order: ["a", "b", "c"],
            palettes: ["a": [red], "b": [green], "c": [red, green, blue]],
            picked: [:]
        )
        XCTAssertEqual(colors["c"], blue)
    }

    func testMainColorWhenEveryColorIsTaken() {
        let colors = ProfileGlowAssignment.assign(
            order: ["a", "b"],
            palettes: ["a": [red], "b": [red]],
            picked: [:]
        )
        XCTAssertEqual(colors["b"], red)
    }

    func testPickedColorWinsAndIsClaimedFirst() {
        let colors = ProfileGlowAssignment.assign(
            order: ["a", "b"],
            palettes: ["a": [red, blue], "b": [green]],
            picked: ["b": red]
        )
        XCTAssertEqual(colors["b"], red)
        XCTAssertEqual(colors["a"], blue)
    }

    func testProfileWithoutPhotoOrPickIsLeftOut() {
        let colors = ProfileGlowAssignment.assign(order: ["a", "b"], palettes: ["a": [red]], picked: [:])
        XCTAssertNil(colors["b"])
    }

    func testPickForAnUnlistedProfileIsDroppedAndNotClaimed() {
        let colors = ProfileGlowAssignment.assign(
            order: ["a"],
            palettes: ["a": [red, blue]],
            picked: ["gone": red]
        )
        XCTAssertNil(colors["gone"])
        XCTAssertEqual(colors["a"], red)
    }

    func testHexRoundTrip() throws {
        let color = try XCTUnwrap(ProfileGlowRGB(hex: "#3366cc"))
        XCTAssertEqual(color.hex, "#3366cc")
    }

    // MARK: Picked colors

    @MainActor
    func testPickedColorIsKeptPerDashboardAndRemovedWithIt() throws {
        let suite = "ProfileGlowColor.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileAppearanceStore(defaults: defaults, avatarsRoot: root, legacyAvatarDirectories: [])
        let first = UUID(), second = UUID()

        store.saveGlowColor("#ff0000", for: "default", dashboardID: first)
        XCTAssertEqual(store.loadGlowColors(dashboardID: first), ["default": "#ff0000"])
        XCTAssertEqual(store.loadGlowColors(dashboardID: second), [:])

        store.saveGlowColor(nil, for: "default", dashboardID: first)
        XCTAssertEqual(store.loadGlowColors(dashboardID: first), [:])

        store.saveGlowColor("#00ff00", for: "work", dashboardID: first)
        store.saveGlowColor("#0000ff", for: "work", dashboardID: second)
        store.removeAll(dashboardID: first)
        XCTAssertEqual(store.loadGlowColors(dashboardID: first), [:])
        XCTAssertEqual(store.loadGlowColors(dashboardID: second), ["work": "#0000ff"])
    }

    // MARK: Helpers

    /// Horizontal bands of solid color, each covering its share of the image.
    private func makeGlowImage(bands: [(ProfileGlowRGB, Double)], side: Int = 64) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        var y = 0.0
        for (color, share) in bands {
            let height = Double(side) * share
            context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: Double(side), height: height))
            y += height
        }
        return try XCTUnwrap(context.makeImage())
    }
}
