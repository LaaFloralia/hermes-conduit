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
    }

    private func capture(style: UIUserInterfaceStyle, mode: WidgetRenderingMode, name: String) throws {
        let now = Date()
        let meters = [("Claude · Session", 12.0), ("Codex · Weekly", 35.0), ("OpenCode · 5h", 72.0)]
            .enumerated().map { index, pair in
                WidgetUsageMeter(id: "\(index)", label: pair.0, remainingPercent: pair.1,
                    observedAt: now, freshUntil: now.addingTimeInterval(1200), resetsAt: now.addingTimeInterval(3600),
                    stale: false, retained: false)
            }
        let usage = WidgetUsageSnapshot(meters: meters, checkedAt: now)
        let snapshot = WidgetSnapshot(appLanguage: "ja", currentWorkspaceID: nil, workspaces: []).withUsage(usage)
        let entry = LAAEmployeeWidgetEntry.make(employee: .ciel, snapshot: snapshot, date: now)
        let screen = LAAEmployeeWidgetView(entry: entry, familyOverride: .systemMedium, renderingModeOverride: mode)
            .frame(width: 382, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: LAARadius.photo))
            .preferredColorScheme(style == .dark ? .dark : .light)
            .ignoresSafeArea()
        let host = UIHostingController(rootView: screen)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 382, height: 180)
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
    }
}
#endif
