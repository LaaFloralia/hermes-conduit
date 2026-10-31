#if LAA_BUILD && LAA_WIDGET_TEST
import SwiftUI
import UIKit
import WidgetKit
import XCTest
@testable import Conduit

@MainActor
final class LAAUsageWidgetSnapshotTests: XCTestCase {
    func testMediumLightDarkAndTinted() throws {
        try capture(style: .light, mode: .fullColor, name: "medium-light")
        try capture(style: .dark, mode: .fullColor, name: "medium-dark")
        try capture(style: .light, mode: .accented, name: "medium-tinted")
        try capture(style: .light, mode: .fullColor, name: "medium-stale-light", stale: true)
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

    func testAccessibilityNoticeIncludesHiddenStaleMeterAndCheckedDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
        }
        let now = try date(2026, 10, 31, 23, 34)
        let fresh = WidgetUsageMeter(id: "fresh", label: "Claude", remainingPercent: 12,
            observedAt: now, freshUntil: now.addingTimeInterval(1200), resetsAt: nil, stale: false, retained: false)
        let stale = WidgetUsageMeter(id: "stale", label: "Codex", remainingPercent: 35,
            observedAt: now, freshUntil: now.addingTimeInterval(1200), resetsAt: nil, stale: true, retained: false)
        let uncertain = WidgetUsageMeter(id: "uncertain", label: "Other", remainingPercent: 50,
            observedAt: now, freshUntil: nil, resetsAt: nil, stale: false, retained: false)
        let manual = WidgetUsageMeter(id: "manual", label: "Other", remainingPercent: 50,
            observedAt: now, freshUntil: nil, resetsAt: nil, stale: false, retained: false, verified: true)
        XCTAssertNil(LAAEmployeeWidgetView.accessibleNotice(for: [fresh], at: now))
        XCTAssertEqual(LAAEmployeeWidgetView.accessibleNotice(for: [fresh, stale], at: now), .stale)
        XCTAssertEqual(LAAEmployeeWidgetView.accessibleNotice(for: [fresh, uncertain], at: now), .uncertain)
        XCTAssertEqual(LAAEmployeeWidgetView.accessibleNotice(for: [fresh, manual], at: now), .manual)
        XCTAssertEqual(LAAEmployeeWidgetView.accessibleNotice(for: [manual, stale], at: now), .stale)
        let today = LAAEmployeeWidgetView.accessibleCheckedParts(now, relativeTo: now, calendar: calendar)
        XCTAssertEqual(today.date, "10/31")
        XCTAssertEqual(today.time, "23:34")
        let yesterday = LAAEmployeeWidgetView.accessibleCheckedParts(try date(2026, 10, 30, 9, 4), relativeTo: now, calendar: calendar)
        XCTAssertEqual(yesterday.date, "10/30")
        XCTAssertEqual(yesterday.time, "09:04")
        let previousYear = LAAEmployeeWidgetView.accessibleCheckedParts(try date(2025, 12, 31, 9, 4), relativeTo: now, calendar: calendar)
        XCTAssertEqual(previousYear.date, "2025/12/31")
        XCTAssertEqual(previousYear.time, "09:04")
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
                         stale: Bool = false, otherOnly: Bool = false, dynamicTypeSize: DynamicTypeSize = .large,
                         checkedAtOffset: TimeInterval = 0, now: Date = Date()) throws -> Data {
        let meters = [("Claude · Session", 12.0), ("Codex · Weekly", 35.0), ("OpenCode · 5h", 72.0)]
            .enumerated().map { index, pair in
                WidgetUsageMeter(id: "\(index)", label: pair.0, remainingPercent: pair.1,
                    observedAt: now, freshUntil: now.addingTimeInterval(1200), resetsAt: now.addingTimeInterval(3600),
                    stale: stale && index != 1, retained: stale && index == 1)
            }
        let usage = WidgetUsageSnapshot(meters: otherOnly ? [] : meters,
            checkedAt: now.addingTimeInterval(checkedAtOffset), hasOtherUsage: otherOnly)
        let snapshot = WidgetSnapshot(appLanguage: "ja", currentWorkspaceID: nil, workspaces: []).withUsage(usage)
        let entry = LAAEmployeeWidgetEntry.make(employee: .ciel, snapshot: snapshot, date: now)
        let screen = LAAEmployeeWidgetView(entry: entry, familyOverride: .systemMedium, renderingModeOverride: mode)
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
