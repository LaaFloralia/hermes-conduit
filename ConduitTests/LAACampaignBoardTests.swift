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
    {"count":3,"items":[
      {"key":"bb8f8dafe0d1dea8","kind":"site","action":"agent_apply","status":"needs_owner","waiting":true,"url":"https://jbia.org/campaign.html","at":"2026-11-15T14:20:38+09:00","decidedAt":null,
       "title":"いい風呂の日キャンペーン（日本浴用剤工業会）","organizer":"日本浴用剤工業会","benefit":"入浴剤セット","deadline":"11月30日 23:59",
       "reason":"応募フォームで規約への同意と本人の住所の入力が必要なため、社長の判断を待っています。","conditions":null,"nextStep":null,"gbizid":null},
      {"key":"e07cb584cf2b6f5f","kind":"x","action":"self","status":"candidate","waiting":true,"url":"https://x.com/nakau_info/status/1","at":"2026-11-15T13:42:12+09:00","decidedAt":null,
       "title":"なか卯【公式】","organizer":null,"benefit":"なか卯お食事券1,000円分（30名）","deadline":"2026-11-15","reason":null,"conditions":"フォロー＋リポスト。23:59まで","nextStep":null,"gbizid":null},
      {"key":"b7b5b1f12181290d","kind":"grant","action":"draft","status":"candidate","waiting":true,"url":"https://example.com/grant","at":"2026-11-15T08:35:54+09:00","decidedAt":null,
       "title":"東京都 新製品・新技術開発助成事業","organizer":"東京都","benefit":"上限25,000,000円","deadline":"2026-04-17","reason":"自社ソフトの新製品開発は候補になり得る。","conditions":null,"nextStep":"GビズID本人確認","gbizid":true},
      {"key":"aaaaaaaaaaaaaaaa","kind":"site","status":"declined","url":"https://example.com/b","at":"2026-11-14T10:00:00+09:00","decidedAt":"2026-11-14T10:00:00+09:00",
       "title":"秋の読書キャンペーン","organizer":null,"benefit":null,"deadline":null,"reason":null,"conditions":null},
      {"key":"cccccccccccccccc","kind":"site","status":"approved","url":"https://example.com/c","at":"2026-11-15T09:00:00+09:00","decidedAt":"2026-11-15T09:00:00+09:00",
       "title":"コーヒー豆プレゼント","organizer":"珈琲店","benefit":"豆 200g","deadline":"12月1日","reason":"抽選","conditions":null}
    ]}
    """#

    private func items() throws -> [LAACampaign] {
        try JSONDecoder().decode(LAACampaignPage.self, from: Data(Self.page.utf8)).items
    }

    func testSectionsSplitByStatusWithTheNewestChoiceFirst() throws {
        let board = LAACampaignBoard()
        board.setForTesting(try items())
        XCTAssertEqual(board.count, 3)
        XCTAssertEqual(board.waiting(.x).map(\.key), ["e07cb584cf2b6f5f"])
        XCTAssertEqual(board.waiting(.grant).map(\.id), ["grant:b7b5b1f12181290d"])
        XCTAssertEqual(board.decided.map(\.key), ["cccccccccccccccc", "aaaaaaaaaaaaaaaa"])
    }

    func testRowTextLeavesOutWhatTheLedgerDoesNotKnow() throws {
        let rows = try items()
        XCTAssertEqual(LAACampaignCopy.meta(rows[0]), "日本浴用剤工業会 · 入浴剤セット · 締切 11月30日 23:59")
        XCTAssertEqual(LAACampaignCopy.meta(rows[2]), "東京都 · 上限25,000,000円 · 締切 2026-04-17 · GビズIDが必要")
        XCTAssertEqual(LAACampaignCopy.meta(rows[3]), "")
        XCTAssertEqual(LAACampaignCopy.body(rows[1]), "フォロー＋リポスト。23:59まで")
        XCTAssertTrue(LAACampaignCopy.decision(rows[4]).hasPrefix("応募させる · "))
        XCTAssertTrue(LAACampaignCopy.decision(rows[3]).hasPrefix("見送る · "))
        XCTAssertEqual(LAACampaignCopy.approve(.x), "自分で応募する")
        XCTAssertEqual(LAACampaignCopy.approve(.grant), "下書きを頼む")
        XCTAssertEqual(rows[0].with(status: "approved", decidedAt: "x").status, "approved")
        XCTAssertFalse(rows[2].with(status: "drafted", decidedAt: "x").changeable)
        XCTAssertTrue(LAACampaignCopy.decision(rows[2].with(status: "drafted", decidedAt: nil)).hasPrefix("下書き済み"))
    }

    /// The Bridge before the kinds sends `prize` and no kind: still a site row.
    func testAnOlderBridgeRowReadsAsASiteEntry() throws {
        let row = try JSONDecoder().decode(LAACampaign.self, from: Data(#"{"key":"aaaaaaaaaaaaaaaa","status":"needs_owner","title":"t","url":"https://example.com","prize":"豆"}"#.utf8))
        XCTAssertEqual(row.kind, .site)
        XCTAssertEqual(row.benefit, "豆")
        XCTAssertTrue(row.waiting)
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
            board.setForTesting(try items(), failures: ["site:cccccccccccccccc": "Macに接続できません。"])
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
