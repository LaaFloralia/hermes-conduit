#if LAA_BUILD && LAA_WIDGET_TEST && DEBUG
import SwiftUI
import UIKit
import WidgetKit
import XCTest
@testable import Conduit

/// Captures of the v2 Usage screen (three provider cards) and the medium
/// widget's six rows, light and dark, at the owner's iPhone and at the
/// smallest supported medium family. Set `LAA_USAGE_SHOT_DIR` (as
/// `TEST_RUNNER_LAA_USAGE_SHOT_DIR`) to also write the PNGs there.
@MainActor
final class LAAUsageV2SnapshotTests: XCTestCase {
    private typealias F = LAAUsageFixtures
    private let now = LAAUsageFixtures.now

    static let proMaxMedium = CGSize(width: 364, height: 170)
    /// The smallest medium family on an iPhone that runs iOS 27.
    static let compactMedium = CGSize(width: 329, height: 155)

    private func entry(_ items: [LAAUsageItem]?, date: Date? = nil, previous: WidgetUsageSnapshot? = nil) -> LAAEmployeeWidgetEntry {
        let usage = items.map { LAAWidgetUsageBuilder.make(items: $0, receivedAt: now, previous: previous) }
        let snapshot = WidgetSnapshot(appLanguage: "ja", currentWorkspaceID: nil, workspaces: []).withUsage(usage)
        return LAAEmployeeWidgetEntry.make(employee: .monet, snapshot: snapshot, date: date ?? now)
    }

    func testMediumWidgetDrawsAllSixRows() throws {
        let live = entry(try F.items())
        XCTAssertEqual(live.usage?.meters.map(\.label), ["Codex 7d", "Claude 5h", "Claude 7d", "Claude Fable", "Google 5h", "Google 7d"])
        for (size, tag) in [(Self.proMaxMedium, "364x170"), (Self.compactMedium, "329x155")] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let name = "v2-widget-\(tag)-\(style == .dark ? "dark" : "light")"
                XCTAssertEqual(try render(live, size: size, style: style, name: name).rows, 6, name)
            }
        }
        try render(live, size: Self.proMaxMedium, style: .light, mode: .accented, name: "v2-widget-364x170-tinted")
        // Unknown Fable and a Google with no account in use keep their rows.
        let unknown = entry(try F.items(fable: nil, googleActive: [:]))
        for style in [UIUserInterfaceStyle.light, .dark] {
            let name = "v2-widget-unknown-329x155-\(style == .dark ? "dark" : "light")"
            XCTAssertEqual(try render(unknown, size: Self.compactMedium, style: style, name: name).rows, 6, name)
        }
        // Low shares: caution and critical bars.
        var rows = F.rows(fable: F.fable(0.0))
        rows[0] = F.quota("codex", label: "Codex", windows: [F.window("Weekly", 8, minutes: 10_080, reset: 3 * 86_400)])
        let low = entry(try F.decode(rows))
        for style in [UIUserInterfaceStyle.light, .dark] {
            try render(low, size: Self.compactMedium, style: style, name: "v2-widget-low-329x155-\(style == .dark ? "dark" : "light")")
        }
        // No snapshot at all: six empty tracks.
        XCTAssertEqual(try render(entry(nil), size: Self.compactMedium, style: .light, name: "v2-widget-empty-329x155").rows, 6)
    }

    /// Larger text shortens and drops the reset time first; only then does a
    /// row give way, the five-hour readings before Fable or Google's week.
    func testLargerTextDropsFiveHourRowsFirst() throws {
        let live = entry(try F.items())
        for (size, tag) in [(Self.proMaxMedium, "364x170"), (Self.compactMedium, "329x155")] {
            var previous = 6
            for type in [DynamicTypeSize.large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility3] {
                let name = "v2-type-\(tag)-\(type)"
                let rows = try XCTUnwrap(try render(live, size: size, style: .light, dynamicTypeSize: type, name: name).rows, name)
                XCTAssertLessThanOrEqual(rows, previous, name)
                XCTAssertGreaterThanOrEqual(rows, 1, name)
                previous = rows
            }
            XCTAssertEqual(try render(live, size: size, style: .light, dynamicTypeSize: .large, name: "v2-type-\(tag)-default").rows, 6)
        }
        XCTAssertEqual(LAAWidgetUsageColumn.rows(dropping: 2).map(\.label), ["Codex 7d", "Claude 7d", "Claude Fable", "Google 7d"])
    }

    /// The timeline has an entry at Fable's reset; from then the Fable row
    /// is unknown while the other Claude rows keep their numbers.
    func testTimelineHandlesFableResetAndExpiry() throws {
        let fableReset = now.addingTimeInterval(1800)
        let usage = LAAWidgetUsageBuilder.make(items: try F.items(fable: F.fable(32.0, reset: 1800)), receivedAt: now)
        let snapshot = WidgetSnapshot(appLanguage: "ja", currentWorkspaceID: nil, workspaces: []).withUsage(usage)
        let timeline = LAAEmployeeTimelineProvider.makeTimeline(configuration: LAAEmployeeWidgetIntent(), snapshot: snapshot)
        let entries = timeline.entries
        let atReset = try XCTUnwrap(entries.first { abs($0.date.timeIntervalSince(fableReset)) < 0.5 }, "an entry at Fable's reset")
        let fable = atReset.usage?.meters.first { $0.id == "provider.claude.quota.fable" }
        let weekly = atReset.usage?.meters.first { $0.id == "provider.claude.quota.weekly" }
        XCTAssertNotNil(LAAWidgetUsageColumn.shown(fable, at: fableReset.addingTimeInterval(-1)))
        XCTAssertNil(LAAWidgetUsageColumn.shown(fable, at: atReset.date))
        XCTAssertEqual(LAAWidgetUsageColumn.shown(weekly, at: atReset.date)?.amount, 49)
        // The freshness deadline (observed + 10 minutes) also has an entry.
        XCTAssertTrue(entries.contains { abs($0.date.timeIntervalSince(now.addingTimeInterval(540))) < 0.5 })
        try render(atReset, size: Self.compactMedium, style: .light, name: "v2-widget-after-fable-reset", renderedAt: atReset.date)
    }

    // MARK: App screen

    func testUsageCardsLightAndDark() async throws {
        let key = "laa.usage.expandedGroups"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let cases: [(String, [LAAUsageItem], String)] = [
            ("normal", try F.items(), ""),
            ("google-open", try F.items(), "provider.google-ai-pro"),
            ("others-open", try F.items(), "others"),
            ("unknown", try F.items(fable: nil, googleActive: [:]), ""),
            ("empty", [], ""),
        ]
        for (name, items, open) in cases {
            UserDefaults.standard.set(open, forKey: key)
            for style in [UIUserInterfaceStyle.light, .dark] {
                let state = LAAUsageState(widgetStore: nil)
                await state.refreshUsage({ items }, now: { self.now })
                try captureScreen(state: state, style: style, name: "v2-usage-\(name)-\(style == .dark ? "dark" : "light")")
            }
        }
        UserDefaults.standard.set("", forKey: key)
        let state = LAAUsageState(widgetStore: nil)
        let items = try F.items()
        await state.refreshUsage({ items }, now: { self.now })
        try captureScreen(state: state, style: .light, name: "v2-usage-accessibility", dynamicTypeSize: .accessibility2)
    }

    // MARK: Rendering

    private final class RowsBox: @unchecked Sendable { var value: Int? }

    private func write(_ png: Data, _ name: String) {
        if let directory = ProcessInfo.processInfo.environment["LAA_USAGE_SHOT_DIR"], !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }

    @discardableResult
    private func render(_ entry: LAAEmployeeWidgetEntry, size: CGSize, style: UIUserInterfaceStyle,
                        mode: WidgetRenderingMode = .fullColor, dynamicTypeSize: DynamicTypeSize = .large,
                        name: String, renderedAt: Date? = nil) throws -> (png: Data, rows: Int?) {
        let box = RowsBox()
        let widget = LAAEmployeeWidgetView(entry: entry, familyOverride: .systemMedium, renderingModeOverride: mode,
                                           renderedAtOverride: renderedAt ?? entry.date)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: LAARadius.photo))
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .onPreferenceChange(LAAWidgetUsageRowsKey.self) { box.value = $0 }
        // WidgetKit draws the container background (`LAAColor.surface`);
        // a hosting controller does not, so the capture lays it underneath.
        let screen = widget
            .background(LAAColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: LAARadius.photo))
            .preferredColorScheme(style == .dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
            .ignoresSafeArea()
        let png = try draw(screen, size: size, style: style, scale: 3, name: name)
        return (png, box.value)
    }

    private func captureScreen(state: LAAUsageState, style: UIUserInterfaceStyle, name: String,
                               dynamicTypeSize: DynamicTypeSize = .large) throws {
        let bridge = LAABridgeSession(statusForTesting: .paired)
        let screen = NavigationStack { LAAUsageView(snapshotState: state) }.environmentObject(bridge)
            .environment(\.locale, Locale(identifier: "ja_JP"))
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .preferredColorScheme(style == .dark ? .dark : .light)
        try draw(screen, size: CGSize(width: 440, height: 956), style: style, scale: 1, name: name, compact: true)
    }

    @discardableResult
    private func draw<Content: View>(_ view: Content, size: CGSize, style: UIUserInterfaceStyle, scale: CGFloat,
                                     name: String, compact: Bool = false) throws -> Data {
        let host = UIHostingController(rootView: view)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        if compact {
            window.traitOverrides.horizontalSizeClass = .compact
            window.traitOverrides.verticalSizeClass = .regular
        }
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
        // 8-bit sRGB, the form `laa-design check` reads.
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let png = try XCTUnwrap(image.pngData())
        write(png, name)
        return png
    }
}
#endif
