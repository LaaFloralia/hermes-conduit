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
        let entry = LAAEmployeeWidgetEntry.make(employee: .monet, snapshot: snapshot, date: now)
        XCTAssertEqual(entry.usage?.meters.map(\.id), ["provider.claude.quota.0"])
    }

    func testLateRenderingKeepsHistoricalNumberAndElapsedTime() {
        let observed = Date(timeIntervalSince1970: 1_000)
        let meter = WidgetUsageMeter(id: "late", label: "Claude Weekly", unit: .percent, amount: 42,
            observedAt: observed, freshUntil: observed.addingTimeInterval(600), resetsAt: nil, stale: false, retained: false)
        XCTAssertFalse(LAAEmployeeWidgetView.isPast(meter, entryDate: observed, renderedAt: observed.addingTimeInterval(599)))
        XCTAssertTrue(LAAEmployeeWidgetView.isPast(meter, entryDate: observed, renderedAt: observed.addingTimeInterval(600)))
        XCTAssertTrue(LAAEmployeeWidgetView.isPast(meter, entryDate: observed.addingTimeInterval(600), renderedAt: observed))
        XCTAssertTrue(meter.hasRecordedValue(at: observed.addingTimeInterval(86400)))
        XCTAssertEqual(LAAEmployeeWidgetView.displayValue(meter, entryDate: observed, renderedAt: observed.addingTimeInterval(599)), "42%")
        XCTAssertEqual(LAAEmployeeWidgetView.displayValue(meter, entryDate: observed, renderedAt: observed.addingTimeInterval(600)), "42% · 10分前")
        XCTAssertEqual(LAAEmployeeWidgetView.displayValue(meter.lastKnown(label: meter.label), entryDate: observed, renderedAt: observed), "42% · 1分未満前")
        XCTAssertTrue(LAAEmployeeWidgetView.timeText(observed, at: observed.addingTimeInterval(86400)).contains("時点"))
        let future = WidgetUsageMeter(id: "future", label: "Claude Weekly", unit: .percent, amount: 42,
            observedAt: observed.addingTimeInterval(121), freshUntil: nil, resetsAt: nil, stale: false, retained: false)
        XCTAssertTrue(LAAEmployeeWidgetView.isPast(future, entryDate: observed, renderedAt: observed.addingTimeInterval(2)))
        XCTAssertFalse(future.hasRecordedValue(at: observed))
    }

    func testThirtyMinuteOutageKeepsNumbersAndResetHistory() throws {
        let observed = Date(timeIntervalSince1970: 1000)
        let stale = WidgetUsageMeter(id: "provider.claude.quota.weekly", label: "Claude", unit: .percent, amount: 42,
            observedAt: observed, freshUntil: observed.addingTimeInterval(600), resetsAt: observed.addingTimeInterval(2000), stale: false, retained: false)
        XCTAssertEqual(LAAEmployeeWidgetView.displayValue(stale, entryDate: observed, renderedAt: observed.addingTimeInterval(1800)), "42% · 30分前")
        XCTAssertEqual(LAAEmployeeWidgetView.displayValue(stale, entryDate: observed, renderedAt: observed.addingTimeInterval(2000)), "42% · 33分前・リセット済み")
        XCTAssertEqual(LAAEmployeeWidgetView.displayValue(.missing(id: "missing", label: "Missing"), entryDate: observed, renderedAt: observed), "未取得")
        for style in [UIUserInterfaceStyle.light, .dark] {
            try capture(style: style, mode: .fullColor, name: "medium-outage-30m-\(style == .dark ? "dark" : "light")",
                        now: observed, renderedAtOffset: 1800)
        }
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

    func testHistoricalWidgetOnWallpaperLightDarkAndTinted() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for mode in [WidgetRenderingMode.fullColor, .accented] {
                let name = "wallpaper-\(style == .dark ? "dark" : "light")-\(mode == .fullColor ? "color" : "tinted")"
                try capture(style: style, mode: mode, name: name, expired: true, wallpaper: true)
            }
        }
    }

    func testMediumWidgetRendersSelectedEmployee() throws {
        let now = Date(timeIntervalSince1970: 1_793_456_040)
        let monet = try capture(style: .light, mode: .fullColor, name: "medium-monet", now: now, employee: .monet)
        let argus = try capture(style: .light, mode: .fullColor, name: "medium-argus", now: now, employee: .argus)
        XCTAssertNotEqual(monet, argus, "The selected employee must change the medium widget's appearance")
    }

    func testMonetVariantsOnWallpaperLightAndDark() throws {
        let now = Date(timeIntervalSince1970: 1_793_456_040)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let appearance = style == .dark ? "dark" : "light"
            let monet = try capture(style: style, mode: .fullColor, name: "monet-\(appearance)",
                                    now: now, wallpaper: true, employee: .monet)
            let uncensored = try capture(style: style, mode: .fullColor, name: "monet-uncensored-\(appearance)",
                                         now: now, wallpaper: true, employee: .monetUncensored)
            XCTAssertNotEqual(monet, uncensored, "Employee variants must render differently")
        }
    }

    func testSmallActionsOnWallpaperLightDarkAndTinted() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for mode in [WidgetRenderingMode.fullColor, .accented] {
                let name = "small-wallpaper-\(style == .dark ? "dark" : "light")-\(mode == .fullColor ? "color" : "tinted")"
                try capture(style: style, mode: mode, name: name, wallpaper: true, small: true)
            }
        }
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
                         checkedAtOffset: TimeInterval = 0, now: Date = Date(), renderedAtOffset: TimeInterval = 0, wallpaper: Bool = false, small: Bool = false,
                         employee: LAAWidgetEmployee = .monet) throws -> Data {
        let rows: [(String, String, WidgetUsageMeter.Unit, Double)] = [
            ("codex.quota.weekly", "Codex Weekly", .percent, 35),
            ("opencode-go.quota.weekly", "OpenCode Weekly", .percent, 72),
            ("claude.quota.weekly", "Claude Weekly", .percent, 12),
            ("venice.balance", "Venice", .usd, 14.5),
            ("magnific.credits", "Magnific", .credits, 236025),
            ("openai-api.balance", "GPT API", .usd, 4.5),
            ("claude-api.balance", "Claude API", .usd, 17.25),
            ("liquid.usage", "Liquid AI", .usd, 1.31),
        ]
        let meters = rows.enumerated().map { index, row in
            WidgetUsageMeter(id: "provider.\(row.0)", label: row.1, unit: row.2, amount: row.3,
                observedAt: now, freshUntil: now.addingTimeInterval(1200), resetsAt: now.addingTimeInterval(3600),
                stale: stale && index != 1, retained: stale && index == 1)
        }
        let usage = WidgetUsageSnapshot(meters: otherOnly ? [] : meters,
            checkedAt: now.addingTimeInterval(checkedAtOffset), hasOtherUsage: otherOnly)
        let snapshot = WidgetSnapshot(appLanguage: "ja", currentWorkspaceID: nil, workspaces: []).withUsage(unset ? nil : usage)
        let entry = LAAEmployeeWidgetEntry.make(employee: employee, snapshot: snapshot,
                                                date: expired ? now.addingTimeInterval(600) : now)
        let widget = LAAEmployeeWidgetView(entry: entry, familyOverride: small ? .systemSmall : .systemMedium, renderingModeOverride: mode, renderedAtOverride: now.addingTimeInterval(renderedAtOffset))
            .frame(width: small ? 169 : 360, height: 169)
            .clipShape(RoundedRectangle(cornerRadius: LAARadius.photo))
            .preferredColorScheme(style == .dark ? .dark : .light)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .ignoresSafeArea()
        let screen = ZStack {
            if wallpaper {
                LinearGradient(colors: [.indigo, .teal, .orange.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.white.opacity(0.18)).frame(width: 280).offset(x: -140, y: 100)
                Capsule().fill(.black.opacity(0.2)).rotationEffect(.degrees(-35)).offset(x: 180)
            }
            widget.background(style == .dark ? Color.black.opacity(0.88) : Color.white.opacity(0.88))
                .clipShape(RoundedRectangle(cornerRadius: LAARadius.photo))
        }.frame(width: wallpaper ? 440 : 360, height: wallpaper ? 956 : 169)
            .ignoresSafeArea()
        let host = UIHostingController(rootView: screen)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: wallpaper ? 440 : 360, height: wallpaper ? 956 : 169)
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let format = UIGraphicsImageRendererFormat(); format.scale = wallpaper ? 1 : 3
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
