#if LAA_BUILD && DEBUG
import SwiftUI
import XCTest
@testable import Conduit

/// What Claude Duet writes through the LAA connector is outside input: it
/// decodes leniently, links open only over https, and nothing is executed.
@MainActor
final class LAADuetFeedTests: XCTestCase {
    func testItemsDecodeLenientlyAndAnUnknownKindIsANote() throws {
        let json = Data("""
        {"items":[{"id":"a","kind":"brief","title":"朝の要約","body":"予定は2件","createdAt":"2026-11-26T08:05:00Z"},
                  {"id":"b","kind":"run_shell","title":"rm -rf /","createdAt":"2026-11-26T09:00:00.120Z"}],
         "status":{"configured":true,"lastPullAt":null,"lastError":null}}
        """.utf8)
        let page = try JSONDecoder().decode(LAADuetItemsPage.self, from: json)
        XCTAssertTrue(page.status.configured)
        XCTAssertEqual(page.items.map(\.kind), [.brief, .other])
        XCTAssertEqual(page.items[1].body, "")
        XCTAssertEqual(LAADuetFormat.kind(page.items[1].kind), "Note")
    }

    func testOnlyAnHTTPSLinkIsOffered() {
        func link(_ value: String?) -> URL? {
            LAADuetItem(id: "x", kind: .update, title: "t", body: "", link: value, createdAt: "").safeLink
        }
        XCTAssertEqual(link("https://example.com/a"), URL(string: "https://example.com/a"))
        XCTAssertNil(link("http://example.com"))
        XCTAssertNil(link("javascript:alert(1)"))
        XCTAssertNil(link("laa://work/sessions"))
        XCTAssertNil(link("https:///nohost"))
        XCTAssertNil(link(nil))
    }

    func testTimesReadInTheDeviceZoneAndABadStampShowsNothing() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(LAADuetFormat.time("2026-11-25T23:05:00Z", calendar: calendar), "11/26 08:05")
        XCTAssertEqual(LAADuetFormat.time("2026-11-25T23:05:00.250Z", calendar: calendar), "11/26 08:05")
        XCTAssertEqual(LAADuetFormat.time("yesterday", calendar: calendar), "")
    }

    func testADuetNotificationLinkOpensOnlyDuetsPage() {
        XCTAssertTrue(LAADuet.opensPage(LAADuet.pageLink))
        XCTAssertFalse(LAADuet.opensPage(URL(string: "laa://chats")))
        XCTAssertFalse(LAADuet.opensPage(URL(string: "laa://work/duet")))
        XCTAssertFalse(LAADuet.opensPage(URL(string: "https://chats/duet")))
        XCTAssertTrue(LAAWorkLinkRequest.shared.open(LAADuet.pageLink))
    }

    func testConnectedDuetPageInLightAndDark() throws {
        let feed = LAADuetFeed()
        feed.setForTesting(items: Self.items, notes: Self.notes)
        for style in [UIUserInterfaceStyle.light, .dark] {
            try LAADuetSnapshot.capture(AnyView(NavigationStack {
                LAADuetView(feed: feed, leaveNote: { _ in true })
            }), name: "duet-connected", style: style, height: 1600, in: self)
        }
    }

    static let items = [
        LAADuetItem(id: "1", kind: .needsOwner, title: "見積の返信先を決めてください",
                    body: "山田様から2通届いています。どちらに返すかを決めていただければ下書きを作ります。",
                    createdAt: "2026-11-26T01:10:00Z"),
        LAADuetItem(id: "2", kind: .brief, title: "朝の要約",
                    body: "今日の予定は2件。10時の打合せは資料が共有済みです。未読の重要なメールはありません。",
                    link: "https://calendar.google.com/", createdAt: "2026-11-25T23:05:00Z"),
        LAADuetItem(id: "3", kind: .done, title: "請求書の下書きを作りました", body: "", createdAt: "2026-11-25T12:40:00Z"),
    ]

    static let notes = [
        LAADuetNote(id: "n1", text: "来週の出張の候補日を調べておいて", createdAt: "2026-11-26T01:30:00Z", state: .queued),
        LAADuetNote(id: "n2", text: "朝の要約は箇条書きで", createdAt: "2026-11-25T10:00:00Z", state: .read),
    ]
}

@MainActor
enum LAADuetSnapshot {
    static func capture(_ content: AnyView, name: String, style: UIUserInterfaceStyle, height: CGFloat = 956,
                        in test: XCTestCase) throws {
        let canvas = CGRect(x: 0, y: 0, width: 440, height: height)
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
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(name)-440x\(Int(height))-\(style == .dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }
}
#endif
