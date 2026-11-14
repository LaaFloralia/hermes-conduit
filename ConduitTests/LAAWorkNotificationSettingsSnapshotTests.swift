#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// 440 × 956 pt light and dark captures of Settings > Notifications > Work:
/// the kinds with their levels under an existing settings card for
/// comparison, and the states before the Mac answers.
@MainActor
final class LAAWorkNotificationSettingsSnapshotTests: XCTestCase {
    private func model(_ phase: LAAWorkNotificationSettingsModel.Phase = .loaded) -> LAAWorkNotificationSettingsModel {
        let model = LAAWorkNotificationSettingsModel()
        model.setForTesting(.init(kinds: ["decision": .alert, "question": .alert, "approval": .alert, "error": .alert,
                                          "finished": .quiet, "task": .alert, "calendar": .alert]), phase: phase)
        return model
    }

    func testWorkNotificationLevelsLightAndDark() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let suffix = style == .dark ? "dark" : "light"
            try capture(screen(model(), reference: true), style: style, name: "notifications-work-\(suffix)")
            try capture(screen(model(.unsupported), reference: false), style: style, name: "notifications-work-unsupported-\(suffix)")
            try capture(screen(model(.unpaired), reference: false), style: style, name: "notifications-work-unpaired-\(suffix)")
        }
    }

    private func screen(_ model: LAAWorkNotificationSettingsModel, reference: Bool) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if reference {
                        // The card the section sits under in Settings, to compare against.
                        ConduitSettingsSection(title: "Notify me when", symbol: "slider.horizontal.3", tint: .conduitAccent) {
                            Toggle(isOn: .constant(true)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: "Response ready")
                                    Text(verbatim: "An active turn finishes").font(.caption).foregroundStyle(.secondary)
                                }
                            }.tint(.conduitAccent)
                        }
                    }
                    LAAWorkNotificationSettingsRows(model: model) { _, _ in }
                }
                .padding(20)
            }
            .background(LAAColor.background.ignoresSafeArea())
            .navigationTitle(Text(verbatim: "Notifications"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func capture<V: View>(_ view: V, style: UIUserInterfaceStyle, name: String, settle: TimeInterval = 0.5) throws {
        let screen = view
            .environment(\.locale, Locale(identifier: "ja_JP"))
            .preferredColorScheme(style == .dark ? .dark : .light)
        let host = UIHostingController(rootView: screen)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.verticalSizeClass = .regular
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        XCTAssertEqual(image.cgImage?.width, 440)
        XCTAssertEqual(image.cgImage?.height, 956)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
