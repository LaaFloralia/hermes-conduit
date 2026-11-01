#if LAA_BUILD && LAA_WIDGET_TEST
import SwiftUI
import UIKit
import WidgetKit
import XCTest
@testable import Conduit

@MainActor
final class LAAUsageWidgetSnapshotTests: XCTestCase {
    func testOldWidgetSnapshotDoesNotDisplayRetiredProviders() {
        let now = Date()
        let meters = ["fal", "venice", "jev", "google-cloud", "google-flow", "claude"].map { id in
            WidgetUsageMeter(id: "provider.\(id).quota.0", label: id, unit: .percent, amount: 42,
                observedAt: now, freshUntil: now.addingTimeInterval(600), resetsAt: nil, stale: false, retained: false)
        }
        let usage = WidgetUsageSnapshot(meters: meters, checkedAt: now)
        let snapshot = WidgetSnapshot(appLanguage: "en", currentWorkspaceID: nil, workspaces: []).withUsage(usage)
        let entry = LAAEmployeeWidgetEntry.make(employee: .ciel, snapshot: snapshot, date: now)
        XCTAssertEqual(entry.usage?.meters.map(\.id), ["provider.claude.quota.0"])
    }

    func testLateRenderingOfEarlierEntryNeverShowsItsExpiredNumber() {
        let observed = Date(timeIntervalSince1970: 1_000)
        let meter = WidgetUsageMeter(id: "late", label: "Claude Weekly", unit: .percent, amount: 42,
            observedAt: observed, freshUntil: observed.addingTimeInterval(600), resetsAt: nil, stale: false, retained: false)
        XCTAssertFalse(LAAEmployeeWidgetView.isPast(meter, entryDate: observed, renderedAt: observed.addingTimeInterval(599)))
        XCTAssertTrue(LAAEmployeeWidgetView.isPast(meter, entryDate: observed, renderedAt: observed.addingTimeInterval(600)))
        XCTAssertTrue(LAAEmployeeWidgetView.isPast(meter, entryDate: observed.addingTimeInterval(600), renderedAt: observed))
        let future = WidgetUsageMeter(id: "future", label: "Claude Weekly", unit: .percent, amount: 42,
            observedAt: observed.addingTimeInterval(121), freshUntil: nil, resetsAt: nil, stale: false, retained: false)
        XCTAssertTrue(LAAEmployeeWidgetView.isPast(future, entryDate: observed, renderedAt: observed.addingTimeInterval(2)))
    }

    func testLateEntryRendersLikeExpiredTimelineEntry() throws {
        let now = Date(timeIntervalSince1970: 1_793_456_040)
        let fresh = try capture(style: .light, mode: .fullColor, name: "medium-before-expiry", now: now)
        let late = try capture(style: .light, mode: .fullColor, name: "medium-late-draw", now: now, renderedAtOffset: 600)
        let expired = try capture(style: .light, mode: .fullColor, name: "medium-expiry-entry", expired: true, now: now, renderedAtOffset: 600)
        XCTAssertNotEqual(late, fresh)
        XCTAssertEqual(late, expired)
    }
    func testMediumLightDarkAndTinted() throws {
        try capture(style: .light, mode: .fullColor, name: "medium-light")
        try capture(style: .dark, mode: .fullColor, name: "medium-dark")
        try capture(style: .light, mode: .accented, name: "medium-tinted")
        try capture(style: .light, mode: .fullColor, name: "medium-expired-light", expired: true)
        try capture(style: .dark, mode: .fullColor, name: "medium-expired-dark", expired: true)
        try capture(style: .light, mode: .fullColor, name: "medium-unset-light", unset: true)
        try capture(style: .dark, mode: .fullColor, name: "medium-unset-dark", unset: true)
        try capture(style: .light, mode: .fullColor, name: "medium-stale-light", stale: true)
        try capture(style: .light, mode: .fullColor, name: "medium-stale-older-light", stale: true, checkedAtOffset: -86_400)
        try capture(style: .dark, mode: .fullColor, name: "medium-stale-dark", stale: true)
        try capture(style: .light, mode: .accented, name: "medium-stale-tinted", stale: true)
        try capture(style: .light, mode: .fullColor, name: "medium-no-quota-light", otherOnly: true)
        try capture(style: .dark, mode: .fullColor, name: "medium-no-quota-dark", otherOnly: true)
        try capture(style: .light, mode: .accented, name: "medium-no-quota-tinted", otherOnly: true)
        try capture(style: .light, mode: .fullColor, name: "medium-accessibility-light", dynamicTypeSize: .accessibility3)
        try capture(style: .dark, mode: .fullColor, name: "medium-accessibility-dark", dynamicTypeSize: .accessibility3)
        try capture(style: .light, mode: .accented, name: "medium-accessibility-tinted", dynamicTypeSize: .accessibility3)
        try capture(style: .light, mode: .fullColor, name: "medium-stale-accessibility-light", stale: true, dynamicTypeSize: .accessibility3)
        try capture(style: .dark, mode: .fullColor, name: "medium-stale-accessibility-dark", stale: true, dynamicTypeSize: .accessibility3)
        try capture(style: .light, mode: .accented, name: "medium-stale-accessibility-tinted", stale: true, dynamicTypeSize: .accessibility3)
        try capture(style: .light, mode: .fullColor, name: "medium-stale-older-accessibility-light", stale: true, dynamicTypeSize: .accessibility3, checkedAtOffset: -370 * 86_400)
        try capture(style: .dark, mode: .fullColor, name: "medium-stale-older-accessibility-dark", stale: true, dynamicTypeSize: .accessibility3, checkedAtOffset: -370 * 86_400)
        try capture(style: .light, mode: .accented, name: "medium-stale-older-accessibility-tinted", stale: true, dynamicTypeSize: .accessibility3, checkedAtOffset: -370 * 86_400)
        try capture(style: .light, mode: .fullColor, name: "medium-no-quota-accessibility-light", otherOnly: true, dynamicTypeSize: .accessibility3)
        try capture(style: .dark, mode: .fullColor, name: "medium-no-quota-accessibility-dark", otherOnly: true, dynamicTypeSize: .accessibility3)
        try capture(style: .light, mode: .accented, name: "medium-no-quota-accessibility-tinted", otherOnly: true, dynamicTypeSize: .accessibility3)
        try capture(style: .light, mode: .fullColor, name: "medium-no-quota-older-accessibility-light", otherOnly: true, dynamicTypeSize: .accessibility3, checkedAtOffset: -370 * 86_400)
        try capture(style: .dark, mode: .fullColor, name: "medium-no-quota-older-accessibility-dark", otherOnly: true, dynamicTypeSize: .accessibility3, checkedAtOffset: -370 * 86_400)
        try capture(style: .light, mode: .accented, name: "medium-no-quota-older-accessibility-tinted", otherOnly: true, dynamicTypeSize: .accessibility3, checkedAtOffset: -370 * 86_400)
        try capture(style: .light, mode: .fullColor, name: "medium-stale-accessibility5-light", stale: true, dynamicTypeSize: .accessibility5)
        try capture(style: .dark, mode: .fullColor, name: "medium-stale-accessibility5-dark", stale: true, dynamicTypeSize: .accessibility5)
        try capture(style: .light, mode: .accented, name: "medium-stale-accessibility5-tinted", stale: true, dynamicTypeSize: .accessibility5)
        try capture(style: .light, mode: .fullColor, name: "medium-stale-older-accessibility5-light", stale: true, dynamicTypeSize: .accessibility5, checkedAtOffset: -370 * 86_400)
        try capture(style: .dark, mode: .fullColor, name: "medium-stale-older-accessibility5-dark", stale: true, dynamicTypeSize: .accessibility5, checkedAtOffset: -370 * 86_400)
        try capture(style: .light, mode: .accented, name: "medium-stale-older-accessibility5-tinted", stale: true, dynamicTypeSize: .accessibility5, checkedAtOffset: -370 * 86_400)
        try capture(style: .light, mode: .fullColor, name: "medium-no-quota-accessibility5-light", otherOnly: true, dynamicTypeSize: .accessibility5)
        try capture(style: .dark, mode: .fullColor, name: "medium-no-quota-accessibility5-dark", otherOnly: true, dynamicTypeSize: .accessibility5)
        try capture(style: .light, mode: .accented, name: "medium-no-quota-accessibility5-tinted", otherOnly: true, dynamicTypeSize: .accessibility5)
        try capture(style: .light, mode: .fullColor, name: "medium-no-quota-older-accessibility5-light", otherOnly: true, dynamicTypeSize: .accessibility5, checkedAtOffset: -370 * 86_400)
        try capture(style: .dark, mode: .fullColor, name: "medium-no-quota-older-accessibility5-dark", otherOnly: true, dynamicTypeSize: .accessibility5, checkedAtOffset: -370 * 86_400)
        try capture(style: .light, mode: .accented, name: "medium-no-quota-older-accessibility5-tinted", otherOnly: true, dynamicTypeSize: .accessibility5, checkedAtOffset: -370 * 86_400)
    }

    func testAccessibility5MatchesAccessibility3() throws {
        let now = Date(timeIntervalSince1970: 1_793_456_040)
        let appearances: [(String, UIUserInterfaceStyle, WidgetRenderingMode)] = [
            ("light", .light, .fullColor), ("dark", .dark, .fullColor), ("tinted", .light, .accented)
        ]
        for (name, style, mode) in appearances {
            for otherOnly in [false, true] {
                let state = otherOnly ? "no-quota" : "stale"
                let reference = try capture(style: style, mode: mode, name: "compare-\(state)-\(name)-ax3",
                    stale: !otherOnly, otherOnly: otherOnly, dynamicTypeSize: .accessibility3, now: now)
                let maximum = try capture(style: style, mode: mode, name: "compare-\(state)-\(name)-ax5",
                    stale: !otherOnly, otherOnly: otherOnly, dynamicTypeSize: .accessibility5, now: now)
                XCTAssertEqual(maximum, reference, "\(state), \(name)")
            }
        }
    }

    @discardableResult
    private func capture(style: UIUserInterfaceStyle, mode: WidgetRenderingMode, name: String,
                         stale: Bool = false, otherOnly: Bool = false, expired: Bool = false, unset: Bool = false,
                         dynamicTypeSize: DynamicTypeSize = .large,
                         checkedAtOffset: TimeInterval = 0, now: Date = Date(), renderedAtOffset: TimeInterval = 0) throws -> Data {
        let meters = [("Claude Weekly", 12.0), ("Codex Weekly", 35.0), ("OpenCode Weekly", 72.0)]
            .enumerated().map { index, pair in
                WidgetUsageMeter(id: "provider.\(["claude", "codex", "opencode-go"][index]).quota.weekly", label: pair.0, unit: .percent, amount: pair.1,
                    observedAt: now, freshUntil: now.addingTimeInterval(1200), resetsAt: now.addingTimeInterval(3600),
                    stale: stale && index != 1, retained: stale && index == 1)
            }
        let usage = WidgetUsageSnapshot(meters: otherOnly ? [] : meters,
            checkedAt: now.addingTimeInterval(checkedAtOffset), hasOtherUsage: otherOnly)
        let snapshot = WidgetSnapshot(appLanguage: "ja", currentWorkspaceID: nil, workspaces: []).withUsage(unset ? nil : usage)
        let entry = LAAEmployeeWidgetEntry.make(employee: .ciel, snapshot: snapshot,
                                                date: expired ? now.addingTimeInterval(600) : now)
        let screen = LAAEmployeeWidgetView(entry: entry, familyOverride: .systemMedium, renderingModeOverride: mode, renderedAtOverride: now.addingTimeInterval(renderedAtOffset))
            .frame(width: 360, height: 169)
            .clipShape(RoundedRectangle(cornerRadius: LAARadius.photo))
            .preferredColorScheme(style == .dark ? .dark : .light)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .ignoresSafeArea()
        let host = UIHostingController(rootView: screen)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 169)
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return try XCTUnwrap(image.pngData())
    }
}
#endif
