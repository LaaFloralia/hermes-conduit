#if LAA_BUILD
import Foundation
import SwiftUI

/// A campaign-hunt ledger entry. Only verified, live rows are shown. Kinds
/// and categories are open; `browse` is a deal without an application.
struct LAACampaign: Codable, Equatable, Identifiable, Sendable {
    struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        static let site = Kind(rawValue: "site")
        static let x = Kind(rawValue: "x")
        static let grant = Kind(rawValue: "grant")
        static let deal = Kind(rawValue: "deal")
    }

    /// The owner's grouping (2026-11-15 19:05): prizes, sign-up rewards,
    /// grants, features a condition unlocks, and offers of services in use.
    struct Category: RawRepresentable, Codable, Hashable, Sendable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        static let prize = Category(rawValue: "prize")
        static let signup = Category(rawValue: "signup")
        static let grant = Category(rawValue: "grant")
        static let unlock = Category(rawValue: "unlock")
        static let perk = Category(rawValue: "perk")
        static let deal = Category(rawValue: "deal")
        static let known: [Category] = [.prize, .signup, .grant, .unlock, .perk, .deal]
    }

    let key: String
    let kind: Kind
    let action: String?
    let category: Category
    /// Version 3 of the ledger: the category's own name, a genre (AI・開発,
    /// 通信, 食品…), a perk's service, and when the row was first listed.
    var categoryLabel: String? = nil
    var genre: String? = nil
    var service: String? = nil
    var addedAt: String? = nil
    let status: String
    let eligible: Bool
    let title: String
    let organizer: String?
    let benefit: String?
    let deadline: String?
    let reason: String?
    let conditions: String?
    let nextStep: String?
    let gbizid: Bool?
    let url: String
    let at: String?
    let decidedAt: String?

    var id: String { "\(kind.rawValue):\(key)" }
    /// The ledger's action, or the one an older Bridge implied by the kind.
    var act: String {
        if let action { return action }
        switch kind {
        case .x: return "self"
        case .grant: return "draft"
        case .site: return "agent_apply"
        case .deal: return "browse"
        default: return "proceed"
        }
    }
    var waiting: Bool { kind != .deal && (status == "needs_owner" || status == "candidate") }
    var applied: Bool { status == "applied" }
    var listed: Bool { kind == .deal && status == "listed" }
    var approved: Bool { status == "approved" }
    /// A drafted grant has been acted on; the ledger no longer takes a change.
    var changeable: Bool { status == "approved" || status == "declined" }

    private enum CodingKeys: String, CodingKey {
        case key, kind, action, category, categoryLabel, genre, service, addedAt, status, eligible, title, organizer, benefit, prize, deadline, reason, conditions, nextStep, gbizid, url, at, decidedAt
    }

    init(key: String, kind: Kind, action: String? = nil, category: Category? = nil, status: String, eligible: Bool = false, title: String, organizer: String?, benefit: String?, deadline: String?,
         reason: String?, conditions: String?, nextStep: String?, gbizid: Bool?, url: String, at: String?, decidedAt: String?) {
        self.key = key; self.kind = kind; self.action = action
        self.category = category ?? (kind == .grant ? .grant : kind == .deal ? .deal : .prize)
        self.status = status; self.eligible = eligible; self.title = title; self.organizer = organizer
        self.benefit = benefit; self.deadline = deadline; self.reason = reason; self.conditions = conditions
        self.nextStep = nextStep; self.gbizid = gbizid; self.url = url; self.at = at; self.decidedAt = decidedAt
    }

    /// A Bridge from before the kinds sends site rows only, with `prize`.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .site
        self.init(key: try values.decode(String.self, forKey: .key),
                  kind: kind,
                  action: try values.decodeIfPresent(String.self, forKey: .action),
                  category: try values.decodeIfPresent(Category.self, forKey: .category),
                  status: try values.decode(String.self, forKey: .status),
                  eligible: try values.decodeIfPresent(Bool.self, forKey: .eligible) ?? false,
                  title: try values.decode(String.self, forKey: .title),
                  organizer: try values.decodeIfPresent(String.self, forKey: .organizer),
                  benefit: try values.decodeIfPresent(String.self, forKey: .benefit)
                      ?? values.decodeIfPresent(String.self, forKey: .prize),
                  deadline: try values.decodeIfPresent(String.self, forKey: .deadline),
                  reason: try values.decodeIfPresent(String.self, forKey: .reason),
                  conditions: try values.decodeIfPresent(String.self, forKey: .conditions),
                  nextStep: try values.decodeIfPresent(String.self, forKey: .nextStep),
                  gbizid: try values.decodeIfPresent(Bool.self, forKey: .gbizid),
                  url: try values.decode(String.self, forKey: .url),
                  at: try values.decodeIfPresent(String.self, forKey: .at),
                  decidedAt: try values.decodeIfPresent(String.self, forKey: .decidedAt))
        categoryLabel = try values.decodeIfPresent(String.self, forKey: .categoryLabel)
        genre = try values.decodeIfPresent(String.self, forKey: .genre)
        service = try values.decodeIfPresent(String.self, forKey: .service)
        addedAt = try values.decodeIfPresent(String.self, forKey: .addedAt) ?? at
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key); try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(action, forKey: .action); try values.encode(category, forKey: .category); try values.encode(status, forKey: .status)
        try values.encode(eligible, forKey: .eligible); try values.encode(title, forKey: .title); try values.encodeIfPresent(organizer, forKey: .organizer)
        try values.encodeIfPresent(benefit, forKey: .benefit); try values.encodeIfPresent(deadline, forKey: .deadline)
        try values.encodeIfPresent(reason, forKey: .reason); try values.encodeIfPresent(conditions, forKey: .conditions)
        try values.encodeIfPresent(nextStep, forKey: .nextStep); try values.encodeIfPresent(gbizid, forKey: .gbizid)
        try values.encode(url, forKey: .url); try values.encodeIfPresent(at, forKey: .at)
        try values.encodeIfPresent(decidedAt, forKey: .decidedAt)
        try values.encodeIfPresent(categoryLabel, forKey: .categoryLabel); try values.encodeIfPresent(genre, forKey: .genre)
        try values.encodeIfPresent(service, forKey: .service); try values.encodeIfPresent(addedAt, forKey: .addedAt)
    }

    func with(status: String, decidedAt: String?) -> LAACampaign {
        var copy = LAACampaign(key: key, kind: kind, action: action, category: category, status: status, eligible: eligible, title: title,
                               organizer: organizer, benefit: benefit, deadline: deadline, reason: reason, conditions: conditions,
                               nextStep: nextStep, gbizid: gbizid, url: url, at: at, decidedAt: decidedAt)
        copy.categoryLabel = categoryLabel; copy.genre = genre; copy.service = service; copy.addedAt = addedAt
        return copy
    }
}

struct LAACampaignPage: Decodable, Sendable {
    let count: Int
    let items: [LAACampaign]
}

struct LAACampaignDecision: Decodable, Sendable {
    let key: String
    let kind: LAACampaign.Kind?
    let status: String
    let decidedAt: String?
}

/// The list is a calendar in words (owner, 2026-11-15 17:17): waiting rows
/// grouped by deadline day, soonest first, then the ones without a date. A row
/// whose deadline day has passed is gone from the list (2026-11-15 19:05).
/// The default is by category, then genre (the owner, 2026-11-15 via the
/// ledger's version 3); the owner may instead order by deadline or by when a
/// row was added.
enum LAACampaignSchedule {
    enum Order: String, CaseIterable, Identifiable {
        case category, deadline, newest
        var id: String { rawValue }
    }

    struct Group: Identifiable, Equatable {
        let id: String
        let title: String
        let urgent: Bool
        let items: [LAACampaign]
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar
    }

    /// `2026-11-30`, `2026-11-30 23:59` or `11月30日` → that day; anything else
    /// (`通年`, `投稿で確認`) has no day.
    static func day(_ deadline: String?, now: Date = Date()) -> Date? {
        guard let deadline else { return nil }
        let calendar = calendar
        let digits = deadline.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if deadline.range(of: #"^\d{4}-\d{1,2}-\d{1,2}"#, options: .regularExpression) != nil, digits.count >= 3 {
            return calendar.date(from: DateComponents(year: digits[0], month: digits[1], day: digits[2]))
        }
        if deadline.range(of: #"^\d{1,2}月\d{1,2}日"#, options: .regularExpression) != nil, digits.count >= 2 {
            let year = calendar.component(.year, from: now)
            return calendar.date(from: DateComponents(year: year, month: digits[0], day: digits[1]))
        }
        return nil
    }

    /// Comparing with `<` only (PROJECT-RULES: no Date <= or >=).
    static func expired(_ item: LAACampaign, now: Date = Date()) -> Bool {
        guard let day = day(item.deadline, now: now) else { return false }
        return day < calendar.startOfDay(for: now)
    }

    static func groups(_ waiting: [LAACampaign], order: Order = .category, now: Date = Date()) -> [Group] {
        let live = waiting.filter { !expired($0, now: now) }
        switch order {
        case .deadline: return byDeadline(live, now: now)
        case .newest:
            let items = live.sorted { ($0.addedAt ?? $0.at ?? "") > ($1.addedAt ?? $1.at ?? "") }
            return items.isEmpty ? [] : [Group(id: "newest", title: "追加順", urgent: false, items: items)]
        case .category:
            let soonest: (LAACampaign, LAACampaign) -> Bool = { a, b in
                switch (day(a.deadline, now: now), day(b.deadline, now: now)) {
                case let (x?, y?): x < y
                case (.some, nil): true
                default: false
                }
            }
            let order = categories(in: live)
            // Within a category, one group per genre by name; rows without a genre last.
            return order.flatMap { category -> [Group] in
                let rows = live.filter { $0.category == category }
                var genres: [String?] = Set(rows.compactMap(\.genre)).sorted().map { $0 }
                if rows.contains(where: { $0.genre == nil }) { genres.append(nil) }
                let name = rows.first.map { LAACampaignCopy.category($0) } ?? LAACampaignCopy.category(category)
                return genres.map { genre in
                    Group(id: "category-\(category.rawValue)-\(genre ?? "")", title: genre.map { "\(name) · \($0)" } ?? name,
                          urgent: false, items: rows.filter { $0.genre == genre }.sorted(by: soonest))
                }
            }
        }
    }

    static func categories(in items: [LAACampaign]) -> [LAACampaign.Category] {
        let present = Set(items.map(\.category))
        return LAACampaign.Category.known.filter(present.contains)
            + present.subtracting(LAACampaign.Category.known).sorted { $0.rawValue < $1.rawValue }
    }

    private static func byDeadline(_ live: [LAACampaign], now: Date) -> [Group] {
        let calendar = calendar
        let today = calendar.startOfDay(for: now)
        var dated: [Date: [LAACampaign]] = [:]
        var undated: [LAACampaign] = []
        for item in live {
            guard let day = day(item.deadline, now: now) else { undated.append(item); continue }
            dated[day, default: []].append(item)
        }
        let format = DateFormatter()
        format.calendar = calendar; format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "ja_JP"); format.dateFormat = "M月d日（E）"
        var out = dated.keys.sorted().map { day -> Group in
            let isToday = day == today
            let isTomorrow = calendar.date(byAdding: .day, value: 1, to: today) == day
            let suffix = isToday ? " 今日まで" : isTomorrow ? " 明日まで" : "まで"
            return Group(id: "day-\(Int(day.timeIntervalSince1970))", title: format.string(from: day) + suffix,
                         urgent: isToday || isTomorrow, items: dated[day] ?? [])
        }
        if !undated.isEmpty { out.append(Group(id: "undated", title: "締切なし・要確認", urgent: false, items: undated)) }
        return out
    }
}

enum LAACampaignCopy {
    static let section = "Campaigns"
    static let heading = "応募の判断"
    static let decided = "Decided"
    static let applied = "応募済み"
    static let appliedFilter = "応募済"
    static let decline = "見送る"
    static let open = "Open"
    static let empty = "該当する応募・特典はありません"
    static let unsupported = "Macのアップデート待ちです"
    static let unsupportedDetail = "MacのLAA Bridgeを更新すると、応募の判断を表示します。"

    static func order(_ order: LAACampaignSchedule.Order) -> String {
        switch order {
        case .category: "種類・ジャンル順"
        case .deadline: "期限順"
        case .newest: "追加が新しい順"
        }
    }

    static func category(_ category: LAACampaign.Category) -> String {
        switch category {
        case .prize: "懸賞"
        case .signup: "登録特典"
        case .grant: "助成金・補助金"
        case .unlock: "機能追加"
        case .perk: "利用者特典"
        case .deal: "セール"
        default: "その他"
        }
    }

    /// What 「はい」 means for the row's action: the routine applies, the owner
    /// applies, the routine drafts the application, or the routine proceeds.
    static func approve(_ action: String) -> String {
        switch action {
        case "agent_apply": "応募させる"
        case "self": "応募した"
        case "draft": "申請する"
        default: "進める"
        }
    }

    /// The quiet button on a declined row.
    static func reopen(_ action: String) -> String {
        switch action {
        case "agent_apply": "応募に変える"
        case "self": "応募したに変える"
        case "draft": "申請に変える"
        default: "進めるに変える"
        }
    }

    static func approvedNote(_ action: String) -> String {
        switch action {
        case "agent_apply": "次の11:00の定期実行で応募します。"
        case "self": "応募済みとして記録しました。"
        case "draft": "申請書の下書きをエージェントが作ります。提出とGビズIDの取得は社長が行います。"
        default: "次の定期実行でエージェントが進めます。"
        }
    }

    /// The ledger's name for the row's category, or the app's own.
    static func category(_ item: LAACampaign) -> String { item.categoryLabel ?? category(item.category) }

    /// `追加 11月15日`: when the row was first listed.
    static func added(_ item: LAACampaign) -> String? {
        guard let date = LAAWorkFreshness.date(item.addedAt ?? item.at) else { return nil }
        let format = DateFormatter()
        format.timeZone = TimeZone(identifier: "Asia/Tokyo"); format.locale = Locale(identifier: "ja_JP")
        format.dateFormat = "M月d日"
        return "追加 " + format.string(from: date)
    }

    /// Every row says its category, what it gives, its deadline and when it
    /// was added (the owner, 2026-11-15); X posts retain their source mark.
    /// Under a category heading the category is not repeated (`category: false`).
    static func meta(_ item: LAACampaign, category showsCategory: Bool = true) -> String {
        [showsCategory ? category(item) : nil, item.kind == .x ? "X" : nil, item.organizer, item.service == item.organizer ? nil : item.service, item.benefit,
         item.deadline.map { "締切 \($0)" }, added(item), item.gbizid == true ? "GビズID要" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Why it waits, then the entry conditions (an X post has only these).
    static func body(_ item: LAACampaign) -> String? {
        let parts = [item.reason, item.conditions.map { "条件: \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// `応募させる · 11月15日（日） 17:30`: what was chosen and when.
    static func decision(_ item: LAACampaign) -> String {
        let choice = item.applied ? applied : item.status == "drafted" ? "下書き済み" : item.approved ? approve(item.act) : decline
        guard let date = LAAWorkFreshness.date(item.applied ? item.at : item.decidedAt) else { return choice }
        return choice + " · " + LAADateText.string(date, .dayTime)
    }

    static func error(_ error: Error) -> String {
        if let error = error as? LAABridgeHTTPError {
            switch error.code {
            case "campaign_not_found": return "この応募は台帳に見つかりません。読み直してください。"
            case "campaign_not_pending": return "この応募はすでに処理されています。読み直してください。"
            case "campaign_kind_required": return "種類を特定できませんでした。読み直してください。"
            default: return LAAWorkHTTP.message(error)
            }
        }
        if let error = error as? LAABridgeError { return error.japaneseText }
        return "送信の結果を確認できません。読み直してください。"
    }
}

/// The list's state, shared by the Work hub (the segment's count) and the list.
@MainActor final class LAACampaignBoard: ObservableObject {
    enum Phase: Equatable { case idle, loaded, unsupported, failed(String) }

    @Published private(set) var items: [LAACampaign] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var loading = false
    @Published private(set) var sending: String?
    @Published private(set) var failures: [String: String] = [:]
    private var loadedAt: Date?
    private var now: () -> Date = { Date() }

    /// Expiration also advances locally between reads from the Bridge.
    var current: [LAACampaign] {
        let date = now()
        return items.filter { $0.eligible && !LAACampaignSchedule.expired($0, now: date) }
    }
    var waiting: [LAACampaign] { current.filter(\.waiting) }
    func waiting(_ kind: LAACampaign.Kind) -> [LAACampaign] { waiting.filter { $0.kind == kind } }
    var categories: [LAACampaign.Category] { LAACampaignSchedule.categories(in: current) }
    var count: Int { waiting.count }

    func visible(category: LAACampaign.Category?, appliedOnly: Bool, query: String) -> [LAACampaign] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return current.filter { item in
            guard category == nil || category == item.category else { return false }
            if appliedOnly && !item.applied { return false }
            if term.isEmpty { return appliedOnly || !item.applied }
            return [item.title, item.organizer, item.benefit, LAACampaignCopy.category(item), item.genre, item.service, item.url,
                    item.applied ? LAACampaignCopy.applied : nil].compactMap { $0 }.contains {
                $0.range(of: term, options: [.caseInsensitive, .widthInsensitive]) != nil
            }
        }
    }

    func reset() { items = []; phase = .idle; loadedAt = nil; failures = [:] }

    func refreshIfStale(_ bridge: LAABridgeSession) async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 5, phase == .loaded { return }
        await load(bridge)
    }

    func load(_ bridge: LAABridgeSession) async {
        guard bridge.status == .paired else { items = []; phase = .idle; return }
        loading = true
        defer { loading = false }
        do {
            let page: LAACampaignPage = try await bridge.read("/v1/campaigns?kind=all&status=all")
            items = page.items
            phase = .loaded
            loadedAt = Date()
        } catch is CancellationError {
        } catch let error as LAABridgeError {
            if case .other(status: 404, code: _) = error { items = []; phase = .unsupported }
            else { phase = .failed(error.japaneseText) }
        } catch {
            phase = .failed(LAABridgeError.invalidResponse.japaneseText)
        }
    }

    /// Records the owner's choice. The same choice twice records the same
    /// state, so a failure simply allows another tap.
    func decide(_ item: LAACampaign, approve: Bool, bridge: LAABridgeSession) async {
        guard sending == nil, let live = current.first(where: { $0.id == item.id }), live.waiting || live.changeable else { return }
        struct Body: Encodable { let choice: String; let kind: String }
        sending = item.id
        failures[item.id] = nil
        defer { sending = nil }
        do {
            let body = try JSONEncoder().encode(Body(choice: approve ? "approve" : "decline", kind: item.kind.rawValue))
            let result: LAACampaignDecision = try await LAAWorkHTTP.write(
                bridge, path: "/v1/campaigns/\(item.key)/decide", body: body, key: LAABridgeIdempotencyKey())
            if let index = items.firstIndex(where: { $0.id == item.id }), result.key == item.key {
                items[index] = items[index].with(status: result.status, decidedAt: result.decidedAt)
            }
        } catch is CancellationError {
        } catch {
            failures[item.id] = LAACampaignCopy.error(error)
        }
    }

    #if DEBUG
    func setForTesting(_ items: [LAACampaign], phase: Phase = .loaded, failures: [String: String] = [:], now: Date? = nil) {
        self.items = items; self.phase = phase; self.failures = failures
        if let now { self.now = { now } }
    }
    #endif
}

/// Work › Campaigns: eligible opportunities and choices. Applied entries
/// stay out of the default list but match searches or the 応募済 filter.
struct LAACampaignBoardView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var board: LAACampaignBoard
    @State private var categoryRaw = ""
    @State private var appliedOnly = false
    @State private var query = ""
    @FocusState private var searching: Bool
    @AppStorage("laa.work.campaigns.order") private var orderRaw = LAACampaignSchedule.Order.category.rawValue
    #if DEBUG
    var loadsOnAppear = true
    #endif

    var body: some View {
        content
            .background(LAAColor.background)
            .tint(LAAColor.link)
            .task(id: bridge.revision) {
                #if DEBUG
                guard loadsOnAppear else { return }
                #endif
                await board.refreshIfStale(bridge)
            }
            .accessibilityIdentifier("work.campaigns")
    }

    @ViewBuilder private var content: some View {
        switch board.phase {
        case .unsupported:
            message(LAACampaignCopy.unsupported, detail: LAACampaignCopy.unsupportedDetail, identifier: "work.campaigns.unsupported")
        case .failed(let text) where board.items.isEmpty:
            message("応募の判断を読めません", detail: text, identifier: "work.campaigns.failure", retry: true)
        case .idle where board.loading:
            LAALoadingDots().padding(LAASpacing.x6)
        default:
            if board.items.isEmpty && !board.loading {
                message(LAACampaignCopy.empty, identifier: "work.campaigns.empty")
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if case .failed(let text) = board.phase {
                    HStack(spacing: LAASpacing.x3) {
                        Text(verbatim: text).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                        Spacer(minLength: 0)
                        Button { Task { await board.load(bridge) } } label: { Text(verbatim: "Retry") }
                    }
                    .padding(.bottom, LAASpacing.x3)
                }
                controls.padding(.bottom, LAASpacing.x4)
                let rows = board.visible(category: selectedCategory, appliedOnly: appliedOnly, query: query)
                if rows.isEmpty {
                    Text(verbatim: LAACampaignCopy.empty)
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        .padding(.vertical, LAASpacing.x4)
                        .accessibilityIdentifier("work.campaigns.no-results")
                }
                let groups = LAACampaignSchedule.groups(rows.filter { $0.waiting || $0.listed }, order: order)
                ForEach(groups) { group in
                    sectionTitle(group.title, urgent: group.urgent)
                        .padding(.top, group.id == groups.first?.id ? 0 : LAASpacing.x6)
                        .accessibilityIdentifier("work.campaigns.group.\(group.id)")
                    // Grouped by category, the heading already names it.
                    ForEach(group.items) { row($0, showsCategory: order != .category) }
                }
                let decided = rows.filter { !$0.waiting && !$0.listed && !$0.applied }
                    .sorted { ($0.decidedAt ?? "") > ($1.decidedAt ?? "") }
                if !decided.isEmpty {
                    sectionTitle(LAACampaignCopy.decided).padding(.top, LAASpacing.x6)
                    ForEach(decided) { row($0) }
                }
                let applied = rows.filter(\.applied).sorted { ($0.at ?? "") > ($1.at ?? "") }
                if !applied.isEmpty {
                    sectionTitle(LAACampaignCopy.applied).padding(.top, appliedOnly ? 0 : LAASpacing.x6)
                    ForEach(applied) { row($0) }
                }
            }
            .padding(.horizontal, LAASpacing.horizontal)
            .padding(.top, LAASpacing.x2)
            .padding(.bottom, LAASpacing.x8)
            .laaPageWidth()
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: board.items)
        }
        .refreshable { await board.load(bridge) }
    }

    private var order: LAACampaignSchedule.Order { LAACampaignSchedule.Order(rawValue: orderRaw) ?? .category }
    private var selectedCategory: LAACampaign.Category? { board.categories.first { $0.rawValue == categoryRaw } }
    private func categoryName(_ category: LAACampaign.Category) -> String {
        board.current.first { $0.category == category }.map(LAACampaignCopy.category) ?? LAACampaignCopy.category(category)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LAASpacing.x4) {
                Menu {
                    Picker(selection: $categoryRaw) {
                        Text(verbatim: "All Types").tag("")
                        ForEach(board.categories, id: \.self) { category in
                            Text(verbatim: categoryName(category)).tag(category.rawValue)
                        }
                    } label: { Text(verbatim: "Type") }
                    .pickerStyle(.inline)
                } label: {
                    menuLabel(selectedCategory.map(categoryName) ?? "All Types")
                }
                .accessibilityIdentifier("work.campaigns.category")
                Spacer(minLength: 0)
                Menu {
                    Picker(selection: $appliedOnly) {
                        Text(verbatim: "通常").tag(false)
                        Text(verbatim: LAACampaignCopy.appliedFilter).tag(true)
                    } label: { Text(verbatim: "Status") }
                    .pickerStyle(.inline)
                    Divider()
                    Picker(selection: $orderRaw) {
                        ForEach(LAACampaignSchedule.Order.allCases) { Text(verbatim: LAACampaignCopy.order($0)).tag($0.rawValue) }
                    } label: { Text(verbatim: "Sort Order") }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: appliedOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                        .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(verbatim: "Filter and Sort"))
                .accessibilityValue(Text(verbatim: appliedOnly ? LAACampaignCopy.appliedFilter : ""))
                .accessibilityIdentifier("work.campaigns.display")
            }
            LAASearchField(placeholder: "Search", text: $query,
                           identifier: "work.campaigns.search", focus: $searching)
        }
    }

    private func menuLabel(_ title: String) -> some View {
        Label { Text(verbatim: title) } icon: { Image(systemName: "chevron.down") }
            .laaTextStyle(.secondary).fontWeight(.semibold).foregroundStyle(LAAColor.link)
            .frame(minHeight: LAASpacing.minimumTouchTarget)
            .contentShape(Rectangle())
    }

    private func sectionTitle(_ title: String, urgent: Bool = false) -> some View {
        Text(verbatim: title)
            .laaTextStyle(.section).fontWeight(.semibold).monospacedDigit()
            .foregroundStyle(urgent ? LAAColor.attention : LAAColor.secondaryText)
            .padding(.bottom, LAASpacing.x1)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: LAACampaign, showsCategory: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                Text(verbatim: item.title)
                    .laaTextStyle(.body).fontWeight(.semibold)
                    .foregroundStyle(item.waiting || item.listed ? LAAColor.text : LAAColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // One menu per waiting row, not a pair of buttons under each.
                if item.waiting { choices(item) }
            }
            let meta = LAACampaignCopy.meta(item, category: showsCategory)
            if !meta.isEmpty {
                Text(verbatim: meta).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            if (item.waiting || item.listed), let body = LAACampaignCopy.body(item) {
                Text(verbatim: body).laaTextStyle(.secondary).foregroundStyle(LAAColor.text)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.waiting, let next = item.nextStep {
                Text(verbatim: "必要な準備: " + next).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { if let url = URL(string: item.url) { openURL(url) } } label: {
                Label { Text(verbatim: LAACampaignCopy.open) } icon: { Image(systemName: "arrow.up.right.square") }
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                    .frame(minHeight: LAASpacing.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.url)
            .accessibilityHint(Text(verbatim: URL(string: item.url)?.host() ?? item.url))
            .accessibilityIdentifier("work.campaign.open.\(item.id)")
            if !item.waiting && !item.listed { decided(item) }
            if let failure = board.failures[item.id] {
                Text(verbatim: failure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    .accessibilityIdentifier("work.campaign.failure.\(item.id)")
            }
        }
        .padding(.vertical, LAASpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(LAAColor.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.campaign.\(item.id)")
    }

    @ViewBuilder private func choices(_ item: LAACampaign) -> some View {
        if board.sending == item.id {
            LAALoadingDots()
        } else {
            Menu {
                choiceButton(item, approve: true)
                choiceButton(item, approve: false)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(LAAColor.link)
                    .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(board.sending != nil)
            .accessibilityLabel(Text(verbatim: "Decide"))
            .accessibilityIdentifier("work.campaign.decide.\(item.id)")
        }
    }

    private func decided(_ item: LAACampaign) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            HStack(spacing: LAASpacing.x3) {
                Label { Text(verbatim: LAACampaignCopy.decision(item)) } icon: {
                    Image(systemName: item.approved || item.applied ? "checkmark.circle" : "minus.circle")
                }
                .laaTextStyle(.secondary).fontWeight(.semibold)
                .foregroundStyle(item.approved ? LAAColor.link : LAAColor.secondaryText)
                .accessibilityIdentifier("work.campaign.status.\(item.id)")
                Spacer(minLength: 0)
                // The run reads the choice at its next pass; until then it can change.
                if item.changeable {
                    Button { Task { await board.decide(item, approve: !item.approved, bridge: bridge) } } label: {
                        Text(verbatim: item.approved ? "見送りに変える" : LAACampaignCopy.reopen(item.act))
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                            .frame(minHeight: LAASpacing.minimumTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(board.sending != nil)
                    .accessibilityIdentifier("work.campaign.change.\(item.id)")
                }
            }
            if item.approved {
                Text(verbatim: LAACampaignCopy.approvedNote(item.act)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
        }
    }

    private func choiceButton(_ item: LAACampaign, approve: Bool) -> some View {
        Button { Task { await board.decide(item, approve: approve, bridge: bridge) } } label: {
            Label { Text(verbatim: approve ? LAACampaignCopy.approve(item.act) : LAACampaignCopy.decline) }
            icon: { Image(systemName: approve ? "checkmark.circle" : "minus.circle") }
        }
        .disabled(board.sending != nil)
        .accessibilityIdentifier("work.campaign.\(approve ? "approve" : "decline").\(item.id)")
    }

    private func message(_ title: String, detail: String? = nil, identifier: String, retry: Bool = false) -> some View {
        VStack(spacing: LAASpacing.x3) {
            Text(verbatim: title).laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText).multilineTextAlignment(.center)
            if let detail {
                Text(verbatim: detail).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).multilineTextAlignment(.center)
            }
            if retry {
                Button { Task { await board.load(bridge) } } label: { Text(verbatim: "Retry") }.laaGlassButton()
            }
        }
        .padding(LAASpacing.x8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }
}
#endif
