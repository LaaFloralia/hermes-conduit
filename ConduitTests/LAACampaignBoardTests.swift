#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// Work › Campaigns: the Bridge's rows decode, the sections split by status,
/// and 440 × 956 pt light and dark captures of the list and its states.
@MainActor
final class LAACampaignBoardTests: XCTestCase {
    private static let page = #"""
    {"count":1,"items":[
      {"key":"bb8f8dafe0d1dea8","status":"needs_owner","url":"https://jbia.org/campaign.html","at":"2026-11-15T14:20:38+09:00","decidedAt":null,
       "title":"いい風呂の日キャンペーン（日本浴用剤工業会）","organizer":"日本浴用剤工業会","prize":"入浴剤セット","deadline":"11月30日 23:59",
       "reason":"応募フォームで規約への同意と本人の住所の入力が必要なため、社長の判断を待っています。","conditions":null},
      {"key":"aaaaaaaaaaaaaaaa","status":"declined","url":"https://example.com/b","at":"2026-11-14T10:00:00+09:00","decidedAt":"2026-11-14T10:00:00+09:00",
       "title":"秋の読書キャンペーン","organizer":null,"prize":null,"deadline":null,"reason":null,"conditions":null},
      {"key":"cccccccccccccccc","status":"approved","url":"https://example.com/c","at":"2026-11-15T09:00:00+09:00","decidedAt":"2026-11-15T09:00:00+09:00",
       "title":"コーヒー豆プレゼント","organizer":"珈琲店","prize":"豆 200g","deadline":"12月1日","reason":"抽選","conditions":null}
    ]}
    """#

    private func items() throws -> [LAACampaign] {
        try JSONDecoder().decode(LAACampaignPage.self, from: Data(Self.page.utf8)).items
    }

    func testSectionsSplitByStatusWithTheNewestChoiceFirst() throws {
        let board = LAACampaignBoard()
        board.setForTesting(try items())
        XCTAssertEqual(board.count, 1)
        XCTAssertEqual(board.waiting.map(\.key), ["bb8f8dafe0d1dea8"])
        XCTAssertEqual(board.decided.map(\.key), ["cccccccccccccccc", "aaaaaaaaaaaaaaaa"])
    }

    func testRowTextLeavesOutWhatTheLedgerDoesNotKnow() throws {
        let rows = try items()
        XCTAssertEqual(LAACampaignCopy.meta(rows[0]), "日本浴用剤工業会 · 賞品 入浴剤セット · 締切 11月30日 23:59")
        XCTAssertEqual(LAACampaignCopy.meta(rows[1]), "")
        XCTAssertTrue(LAACampaignCopy.decision(rows[2]).hasPrefix("応募させる · "))
        XCTAssertTrue(LAACampaignCopy.decision(rows[1]).hasPrefix("見送る · "))
        XCTAssertEqual(rows[0].with(status: "approved", decidedAt: "x").status, "approved")
    }

    func testCampaignsIsAWorkSectionWithItsCount() {
        XCTAssertTrue(LAAWorkHub.Section.allCases.contains(.campaigns))
        XCTAssertFalse(LAAWorkHub.Section.campaigns.searchable)
        XCTAssertEqual(LAAWorkHub.Section.campaigns.title, "Campaigns")
    }

    func testCampaignListLightAndDark() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let suffix = style == .dark ? "dark" : "light"
            let board = LAACampaignBoard()
            board.setForTesting(try items(), failures: ["cccccccccccccccc": "Macに接続できません。"])
            try capture(board, style: style, name: "campaigns-\(suffix)")
            let empty = LAACampaignBoard()
            empty.setForTesting([])
            try capture(empty, style: style, name: "campaigns-empty-\(suffix)")
        }
    }

    private func capture(_ board: LAACampaignBoard, style: UIUserInterfaceStyle, name: String) throws {
        var list = LAACampaignBoardView(board: board)
        list.loadsOnAppear = false
        let screen = NavigationStack {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                LAAScreenHeader(title: "Work", identifier: "laa.work.title").padding(.horizontal, LAASpacing.horizontal)
                LAASegmentedControl(values: LAAWorkHub.Section.allCases, selection: .constant(.campaigns),
                                    title: { $0 == .campaigns ? "\($0.title) \(board.count)" : $0.title })
                    .padding(.horizontal, LAASpacing.horizontal)
                list.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(LAAColor.background.ignoresSafeArea())
        }
        .environmentObject(LAABridgeSession())
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        XCTAssertEqual(image.cgImage?.width, 440)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
