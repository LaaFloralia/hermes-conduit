#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// The task list's one line of controls on the real glass (owner,
/// 2026-11-14), light and dark, at the widths it meets: the owner's
/// 440 pt phone list, the Mac column (460 pt less its padding) and a 402 pt
/// phone, where the grouping keeps only its icon. Attachments are exported
/// from the result bundle.
@MainActor
final class LAATaskControlsSnapshotTests: XCTestCase {
    private let counts: [LAATaskQuickFilter: Int] = [.all: 28, .soon: 5, .attention: 6, .ai: 9]

    func testControlsLightAndDark() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            try capture(board, style: style, name: "task-controls-\(style == .dark ? "dark" : "light")")
        }
    }

    /// The line keeps one height whatever is lit, and fits the owner's width
    /// with the grouping's title.
    func testLineFitsTheOwnersWidth() throws {
        let host = UIHostingController(rootView: line(.related, .all, archived: false).frame(width: 392))
        let size = host.sizeThatFits(in: CGSize(width: 392, height: 400))
        XCTAssertEqual(size.height, LAASpacing.minimumTouchTarget, accuracy: 1, "one line, not two")
    }

    private func line(_ filter: LAALinearTaskFilter, _ quick: LAATaskQuickFilter, archived: Bool) -> some View {
        LAATaskControls(filter: .constant(filter), grouping: .constant(.genre), quick: .constant(quick),
                        archived: .constant(archived), counts: counts, shown: 4,
                        allFolded: false, foldAll: { _ in })
    }

    private var board: some View {
        let widths: [(String, CGFloat)] = [("440 iPhone", 392), ("Mac column", 428), ("402 iPhone", 354)]
        let states: [(LAALinearTaskFilter, LAATaskQuickFilter, Bool)] = [
            (.related, .all, false), (.assigned, .all, false), (.created, .attention, false), (.related, .all, true),
        ]
        return VStack(alignment: .leading, spacing: LAASpacing.x4) {
            ForEach(widths, id: \.0) { name, width in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name).font(.caption).foregroundStyle(LAAColor.secondaryText)
                    ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                        self.line(state.0, state.1, archived: state.2).frame(width: width)
                    }
                }
            }
        }
        .padding(.horizontal, LAASpacing.x2)
        .padding(.top, LAASpacing.x6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LAAColor.background.ignoresSafeArea())
    }

    private func capture<V: View>(_ view: V, style: UIUserInterfaceStyle, name: String) throws {
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
