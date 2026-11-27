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
      {"key":"bb8f8dafe0d1dea8","eligible":true,"kind":"site","action":"agent_apply","status":"needs_owner","waiting":true,"url":"https://example.invalid/bath","at":"2026-11-15T14:20:38+09:00","decidedAt":null,
       "title":"いい風呂の日キャンペーン（日本浴用剤工業会）","organizer":"日本浴用剤工業会","benefit":"入浴剤セット","deadline":"11月30日 23:59",
       "reason":"応募フォームで規約への同意と本人の住所の入力が必要なため、社長の判断を待っています。","conditions":null,"nextStep":null,"gbizid":null},
      {"key":"e07cb584cf2b6f5f","eligible":true,"kind":"x","action":"self","status":"candidate","waiting":true,"url":"https://example.invalid/post/1","at":"2026-11-15T13:42:12+09:00","decidedAt":null,
       "title":"なか卯【公式】","genre":"食品","organizer":null,"benefit":"なか卯お食事券1,000円分（30名）","deadline":"2026-11-15","reason":null,"conditions":"フォロー＋リポスト。23:59まで","nextStep":null,"gbizid":null},
      {"key":"b7b5b1f12181290d","eligible":true,"kind":"grant","action":"draft","status":"candidate","waiting":true,"url":"https://example.com/grant","at":"2026-11-15T08:35:54+09:00","decidedAt":null,
       "title":"東京都 新製品・新技術開発助成事業","organizer":"東京都","benefit":"上限25,000,000円","deadline":"2027-04-17","reason":"自社ソフトの新製品開発は候補になり得る。","conditions":null,"nextStep":"GビズID本人確認","gbizid":true},
      {"key":"aaaaaaaaaaaaaaaa","eligible":true,"kind":"site","status":"declined","url":"https://example.com/b","at":"2026-11-14T10:00:00+09:00","decidedAt":"2026-11-14T10:00:00+09:00",
       "title":"秋の読書キャンペーン","organizer":null,"benefit":null,"deadline":null,"reason":null,"conditions":null},
      {"key":"cccccccccccccccc","eligible":true,"kind":"site","status":"approved","url":"https://example.com/c","at":"2026-11-15T09:00:00+09:00","decidedAt":"2026-11-15T09:00:00+09:00",
       "title":"コーヒー豆プレゼント","organizer":"珈琲店","benefit":"豆 200g","deadline":"12月1日","reason":"抽選","conditions":null},
      {"key":"dddddddddddddddd","eligible":true,"kind":"perk","action":"agent_apply","category":"perk","categoryLabel":"利用者特典","genre":"通信","service":"SoftBank","addedAt":"2026-11-15T20:00:00+09:00","status":"candidate","url":"https://example.com/d","at":"2026-11-15T18:00:00+09:00","decidedAt":null,
       "title":"SoftBank ギガ無料","organizer":"SoftBank","benefit":"データ5GB","deadline":"通年","reason":null,"conditions":null},
      {"key":"eeeeeeeeeeeeeeee","eligible":true,"kind":"site","action":"agent_apply","status":"needs_owner","url":"https://example.com/e","at":"2026-11-01T09:00:00+09:00","decidedAt":null,
       "title":"終わった応募","organizer":null,"benefit":null,"deadline":"2026-11-10","reason":null,"conditions":null}
    ]}
    """#

    private func items() throws -> [LAACampaign] {
        try JSONDecoder().decode(LAACampaignPage.self, from: Data(Self.page.utf8)).items
    }

    func testDefaultListUsesOnlyLiveCategories() throws {
        let board = LAACampaignBoard()
        board.setForTesting(try items(), now: try Self.now())
        XCTAssertEqual(board.count, 4, "the row past its deadline is gone")
        XCTAssertEqual(board.waiting(.x).map(\.key), ["e07cb584cf2b6f5f"])
        XCTAssertEqual(board.waiting(.grant).map(\.id), ["grant:b7b5b1f12181290d"])
        XCTAssertEqual(board.current.filter { !$0.waiting }.map(\.key), ["aaaaaaaaaaaaaaaa", "cccccccccccccccc"])
        XCTAssertEqual(board.categories.map(\.rawValue), ["prize", "grant", "perk"])
    }

    private static func now() throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-15T09:00:00Z")) }

    /// A row without a category reads by its kind; a new kind keeps its own.
    func testCategoriesAndActionsFollowTheLedger() throws {
        let rows = try items()
        XCTAssertEqual(rows.map(\.category.rawValue), ["prize", "prize", "grant", "prize", "prize", "perk", "prize"])
        XCTAssertEqual(LAACampaignCopy.approve(rows[5].act), "応募させる")
        XCTAssertEqual(LAACampaignCopy.meta(rows[5]), "利用者特典 · SoftBank · データ5GB · 締切 通年 · 追加 11月15日")
        let feature = try JSONDecoder().decode(LAACampaign.self, from: Data(#"{"key":"ffffffffffffffff","kind":"feature","status":"candidate","title":"t","url":"https://example.com"}"#.utf8))
        XCTAssertEqual([feature.act, LAACampaignCopy.approve(feature.act), LAACampaignCopy.category(feature)], ["proceed", "進める", "懸賞"])
        let byCategory = LAACampaignSchedule.groups(rows.filter(\.waiting), now: try Self.now())
        XCTAssertEqual(byCategory.map(\.title), ["懸賞 · 食品", "懸賞", "助成金・補助金", "利用者特典 · 通信"])
        XCTAssertEqual(byCategory[1].items.map(\.key), ["bb8f8dafe0d1dea8"])
        let newest = LAACampaignSchedule.groups(rows.filter(\.waiting), order: .newest, now: try Self.now())
        XCTAssertEqual(newest.first?.items.first?.key, "dddddddddddddddd")
    }

    func testRowTextLeavesOutWhatTheLedgerDoesNotKnow() throws {
        let rows = try items()
        XCTAssertEqual(LAACampaignCopy.meta(rows[0]), "懸賞 · 日本浴用剤工業会 · 入浴剤セット · 締切 11月30日 23:59 · 追加 11月15日")
        XCTAssertEqual(LAACampaignCopy.meta(rows[1]), "懸賞 · X · なか卯お食事券1,000円分（30名） · 締切 2026-11-15 · 追加 11月15日")
        XCTAssertEqual(LAACampaignCopy.meta(rows[2]), "助成金・補助金 · 東京都 · 上限25,000,000円 · 締切 2027-04-17 · 追加 11月15日 · GビズID要")
        XCTAssertEqual(LAACampaignCopy.meta(rows[3]), "懸賞 · 追加 11月14日")
        XCTAssertEqual(LAACampaignCopy.body(rows[1]), "条件: フォロー＋リポスト。23:59まで")
        XCTAssertTrue(LAACampaignCopy.decision(rows[4]).hasPrefix("応募させる · "))
        XCTAssertTrue(LAACampaignCopy.decision(rows[3]).hasPrefix("見送る · "))
        XCTAssertEqual(LAACampaignCopy.approve(rows[1].act), "応募した")
        XCTAssertEqual(LAACampaignCopy.approve(rows[2].act), "申請する")
        XCTAssertEqual(rows[0].with(status: "approved", decidedAt: "x").status, "approved")
        XCTAssertFalse(rows[2].with(status: "drafted", decidedAt: "x").changeable)
        XCTAssertTrue(LAACampaignCopy.decision(rows[2].with(status: "drafted", decidedAt: nil)).hasPrefix("下書き済み"))
    }

    func testStatusAndSearchNeverSurfaceIneligibleOrExpiredRows() throws {
        let extras = #"""
        [
          {"key":"coffee-site","kind":"site","category":"signup","eligible":true,"status":"applied","title":"Coffee 登録特典","url":"https://example.invalid/1"},
          {"key":"coffee-x","kind":"x","eligible":true,"status":"applied","title":"Coffee 抽選","url":"https://example.invalid/2"},
          {"key":"deal-active","kind":"deal","categoryLabel":"期間限定セール","eligible":true,"status":"listed","title":"Krea 見本","url":"https://example.invalid/3"},
          {"key":"feature-active","kind":"feature","category":"unlock","eligible":true,"status":"candidate","title":"機能の見本","url":"https://example.invalid/4"},
          {"key":"former","kind":"x","eligible":true,"status":"applied","title":"Coffee 旧受付","deadline":"2026-11-14","url":"https://example.invalid/5"},
          {"key":"unqualified","kind":"x","eligible":false,"category":"excluded","status":"applied","title":"Coffee 対象外","url":"https://example.invalid/6"},
          {"key":"unverified","kind":"x","status":"candidate","title":"Coffee 未確認","url":"https://example.invalid/7"}
        ]
        """#
        let newItems = try JSONDecoder().decode([LAACampaign].self, from: Data(extras.utf8))
        let board = LAACampaignBoard()
        board.setForTesting(try items() + newItems, now: try Self.now())
        XCTAssertEqual(board.categories, [.prize, .signup, .grant, .unlock, .perk, .deal])
        XCTAssertFalse(board.visible(category: nil, appliedOnly: false, query: " ").contains(where: \.applied))
        XCTAssertEqual(board.visible(category: nil, appliedOnly: true, query: "").map(\.key), ["coffee-site", "coffee-x"])
        XCTAssertEqual(board.visible(category: nil, appliedOnly: false, query: " ＣＯＦＦＥＥ ").map(\.key), ["coffee-site", "coffee-x"])
        XCTAssertEqual(board.visible(category: .signup, appliedOnly: true, query: "coffee").map(\.key), ["coffee-site"])
        XCTAssertEqual(LAACampaignCopy.decision(newItems[0]), "応募済み")
        XCTAssertFalse(newItems[0].changeable)
        XCTAssertTrue(newItems[0].with(status: "applied", decidedAt: nil).eligible)
        let deal = try XCTUnwrap(board.visible(category: .deal, appliedOnly: false, query: "").first)
        XCTAssertEqual(LAACampaignCopy.category(deal), "期間限定セール")
        XCTAssertTrue(deal.listed)
        XCTAssertFalse(deal.waiting || deal.changeable)
    }

    /// Old rows can decode but are not considered eligible without an explicit flag.
    func testAnOlderBridgeRowReadsAsASiteEntry() throws {
        let row = try JSONDecoder().decode(LAACampaign.self, from: Data(#"{"key":"aaaaaaaaaaaaaaaa","status":"needs_owner","title":"t","url":"https://example.com","prize":"豆"}"#.utf8))
        XCTAssertEqual(row.kind, .site)
        XCTAssertEqual(row.benefit, "豆")
        XCTAssertTrue(row.waiting)
        XCTAssertFalse(row.eligible)
    }

    func testWaitingRowsGroupByDeadlineDay() throws {
        let groups = LAACampaignSchedule.groups(try items().filter(\.waiting), order: .deadline, now: try Self.now())
        XCTAssertEqual(groups.map(\.title), ["11月15日（日） 今日まで", "11月30日（月）まで", "4月17日（土）まで", "締切なし・要確認"])
        XCTAssertFalse(groups.flatMap(\.items).contains { $0.key == "eeeeeeeeeeeeeeee" })
        XCTAssertTrue(groups[0].urgent)
        XCTAssertNil(LAACampaignSchedule.day("通年"))
    }

    func testCampaignsIsOnlyASectionWithinDecisions() {
        XCTAssertEqual(LAAWorkHub.Section.allCases, [.projects, .sessions, .decisions, .tasks])
        XCTAssertFalse(LAAWorkHub.Section.decisions.searchable)
        XCTAssertEqual(LAAWorkHub.DecisionSection.allCases.map(\.title), ["Decisions", "Campaigns"])
    }

    func testCampaignListLightAndDark() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let suffix = style == .dark ? "dark" : "light"
            let board = LAACampaignBoard()
            board.setForTesting(try items(), failures: ["site:cccccccccccccccc": "Macに接続できません。"], now: try Self.now())
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
                LAAWorkSectionSelector(selection: .constant(.decisions), decisions: 0)
                    .padding(.horizontal, LAASpacing.horizontal)
                LAAWorkHub.decisionPicker(selection: .constant(.campaigns))
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
