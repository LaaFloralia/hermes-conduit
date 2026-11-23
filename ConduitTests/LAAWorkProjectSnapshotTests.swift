#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// Work's project screens at the owner's 440 × 956 pt, light and dark: the
/// list and every state of the detail, drawn from the same fixture the
/// screenshots use. Attachments are exported from the result bundle. The
/// largest Dynamic Type size is drawn for the list and the detail as well.
@MainActor
final class LAAWorkProjectSnapshotTests: XCTestCase {
    func testEveryStateLightAndDark() throws {
        for mode in LAAWorkProjectFixtureView.Mode.allCases {
            for style in [UIUserInterfaceStyle.light, .dark] {
                try capture(LAAWorkProjectFixtureView(state: mode), style: style,
                            name: "project-\(mode.rawValue)-\(style == .dark ? "dark" : "light")")
            }
        }
    }

    func testLargestTextSize() throws {
        for mode in [LAAWorkProjectFixtureView.Mode.list, .detail] {
            try capture(LAAWorkProjectFixtureView(state: mode), style: .light,
                        name: "project-\(mode.rawValue)-accessibility3", size: .accessibility3)
        }
    }

    /// The whole detail page, past the first screen: the finished group, the
    /// sessions with their children, the instructions and the files.
    func testDetailFullLength() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let fixture = LAAWorkProjectFixtureView.projects[0]
            let page = LAAWorkProjectPage(project: fixture, detail: LAAWorkProjectSnapshot(fixture), sessions: LAAWorkProjectFixtureView.appSessions,
                                          options: LAAWorkProjectFixtureView.options, phase: .ready)
                .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4)
                .frame(width: 440)
                .background(LAAColor.background)
            let height = UIHostingController(rootView: page).sizeThatFits(in: CGSize(width: 440, height: 10_000)).height
            try capture(page, style: style, name: "project-detail-full-\(style == .dark ? "dark" : "light")",
                        height: ceil(height))
        }
    }

    /// A row without requirements and without a note stays one line of
    /// progress, the same height class as the others.
    func testRowWithoutRequirementsKeepsItsLines() {
        let empty = LAAWorkProjectFixtureView.projects[4]
        let full = LAAWorkProjectFixtureView.projects[1]
        func height(_ project: LAAWorkProject) -> CGFloat {
            UIHostingController(rootView: LAAWorkProjectRow(project: project).frame(width: 400))
                .sizeThatFits(in: CGSize(width: 400, height: 400)).height
        }
        XCTAssertGreaterThanOrEqual(height(empty), LAASpacing.minimumRowHeight)
        XCTAssertLessThan(height(empty), height(full), "no note line when there is no note")
    }

    private func capture<V: View>(_ view: V, style: UIUserInterfaceStyle, name: String,
                                  size: DynamicTypeSize = .large, height: CGFloat = 956) throws {
        let screen = view
            .environment(\.locale, Locale(identifier: "ja_JP"))
            .environment(\.dynamicTypeSize, size)
            .preferredColorScheme(style == .dark ? .dark : .light)
        let host = UIHostingController(rootView: screen)
        // A full-length page is not a screen: no bars, no safe area.
        if height != 956 { host.safeAreaRegions = [] }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: height)
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.verticalSizeClass = .regular
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = true
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
