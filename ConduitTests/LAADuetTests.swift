#if LAA_BUILD && DEBUG
import SwiftUI
import XCTest
@testable import Conduit

/// Claude Duet under 派遣社員 (owner, 2026-11-26): a row after Muse and
/// Dots and a page that hands the owner's words to Duet by the owner's tap.
@MainActor
final class LAADuetTests: XCTestCase {
    func testHandOffCopiesTheTrimmedTextAndOpensTheWebDuet() throws {
        let board = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("laa.duet.test.\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: board.name) }
        var opened: [URL] = []
        let copied = LAADuet.handOff("  明日の予定を確認して\n", pasteboard: board) { opened.append($0) }
        XCTAssertTrue(copied)
        XCTAssertEqual(board.string, "明日の予定を確認して")
        XCTAssertEqual(opened, [URL(string: "https://claude.ai/duet")!])
    }

    func testAnEmptyDraftOpensDuetAndLeavesTheClipboardAlone() throws {
        let board = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("laa.duet.test.\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: board.name) }
        board.string = "前の内容"
        var opened: [URL] = []
        XCTAssertFalse(LAADuet.handOff(" \n ", pasteboard: board) { opened.append($0) })
        XCTAssertEqual(board.string, "前の内容")
        XCTAssertEqual(opened, [LAADuet.webURL])
    }

    /// Duet is no Hermes profile: it never joins calls, groups, the Watch or
    /// task assignment, which all read `LAAStaff`.
    func testDuetIsNotAHermesStaffMember() {
        XCTAssertNil(LAAStaff(profile: "laa-duet"))
        XCTAssertFalse(LAAStaff.allCases.map(\.name).contains(LAADuet.name))
        XCTAssertEqual(LAAStaff.members(of: .contractor), [.monetDots, .soap])
    }

    func testChatListAndDuetPageAtCompactSizeInLightAndDark() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            try capture(AnyView(NavigationStack { LAAChatsFixtureView() }), name: "duet-chats", style: style,
                        scrollToBottom: true)
            try capture(AnyView(NavigationStack { LAADuetView() }), name: "duet-page", style: style)
        }
    }

    private func capture(_ content: AnyView, name: String, style: UIUserInterfaceStyle,
                         scrollToBottom: Bool = false) throws {
        let canvas = CGRect(x: 0, y: 0, width: 440, height: 956)
        let host = UIHostingController(rootView: content.preferredColorScheme(style == .dark ? .dark : .light))
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = canvas
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.verticalSizeClass = .regular
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        if scrollToBottom, let scroll = Self.firstScrollView(in: host.view) {
            let bottom = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(name)-440x956-\(style == .dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
        for child in view.subviews { if let found = firstScrollView(in: child) { return found } }
        return nil
    }
}
#endif
