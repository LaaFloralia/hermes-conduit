#if LAA_BUILD
import Foundation
import SwiftUI

/// One campaign entry from `GET /v1/campaigns?kind=all`. The Bridge passes on
/// the campaign-hunt ledger's rows; personal details never reach the ledger.
/// Three kinds wait for the owner, and approving means something different
/// for each: `site` (the routine applies), `x` (the owner applies on X),
/// `grant` (the routine drafts the application).
struct LAACampaign: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case site, x, grant }

    let key: String
    let kind: Kind
    let status: String
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
    var waiting: Bool { status == "needs_owner" || status == "candidate" }
    var approved: Bool { status == "approved" }
    /// A drafted grant has been acted on; the ledger no longer takes a change.
    var changeable: Bool { status == "approved" || status == "declined" }

    private enum CodingKeys: String, CodingKey {
        case key, kind, status, title, organizer, benefit, prize, deadline, reason, conditions, nextStep, gbizid, url, at, decidedAt
    }

    init(key: String, kind: Kind, status: String, title: String, organizer: String?, benefit: String?, deadline: String?,
         reason: String?, conditions: String?, nextStep: String?, gbizid: Bool?, url: String, at: String?, decidedAt: String?) {
        self.key = key; self.kind = kind; self.status = status; self.title = title; self.organizer = organizer
        self.benefit = benefit; self.deadline = deadline; self.reason = reason; self.conditions = conditions
        self.nextStep = nextStep; self.gbizid = gbizid; self.url = url; self.at = at; self.decidedAt = decidedAt
    }

    /// A Bridge from before the kinds sends site rows only, with `prize`.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try values.decode(String.self, forKey: .key),
                  kind: try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .site,
                  status: try values.decode(String.self, forKey: .status),
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
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key); try values.encode(kind, forKey: .kind); try values.encode(status, forKey: .status)
        try values.encode(title, forKey: .title); try values.encodeIfPresent(organizer, forKey: .organizer)
        try values.encodeIfPresent(benefit, forKey: .benefit); try values.encodeIfPresent(deadline, forKey: .deadline)
        try values.encodeIfPresent(reason, forKey: .reason); try values.encodeIfPresent(conditions, forKey: .conditions)
        try values.encodeIfPresent(nextStep, forKey: .nextStep); try values.encodeIfPresent(gbizid, forKey: .gbizid)
        try values.encode(url, forKey: .url); try values.encodeIfPresent(at, forKey: .at)
        try values.encodeIfPresent(decidedAt, forKey: .decidedAt)
    }

    func with(status: String, decidedAt: String?) -> LAACampaign {
        LAACampaign(key: key, kind: kind, status: status, title: title, organizer: organizer, benefit: benefit,
                    deadline: deadline, reason: reason, conditions: conditions, nextStep: nextStep, gbizid: gbizid,
                    url: url, at: at, decidedAt: decidedAt)
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
/// grouped by deadline day, soonest first, then the ones without a date and
/// the ones already past.
enum LAACampaignSchedule {
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

    static func groups(_ waiting: [LAACampaign], now: Date = Date()) -> [Group] {
        let calendar = calendar
        let today = calendar.startOfDay(for: now)
        var dated: [Date: [LAACampaign]] = [:]
        var undated: [LAACampaign] = []
        var past: [LAACampaign] = []
        for item in waiting {
            guard let day = day(item.deadline, now: now) else { undated.append(item); continue }
            // Comparing with `<` only (PROJECT-RULES: no Date <= or >=).
            if day < today { past.append(item) } else { dated[day, default: []].append(item) }
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
        if !past.isEmpty { out.append(Group(id: "past", title: "締切を過ぎた物", urgent: false, items: past)) }
        return out
    }
}

enum LAACampaignCopy {
    static let section = "Campaigns"
    static let heading = "応募の判断"
    static let waiting = "判断待ち"
    static let decided = "判断済み"
    static let decline = "見送る"
    static let open = "ページを開く"
    static let empty = "判断待ちの応募はありません"
    static let unsupported = "Macのアップデート待ちです"
    static let unsupportedDetail = "MacのLAA Bridgeを更新すると、応募の判断を表示します。"

    /// The section heading for each kind, in the order the list shows them.
    static func group(_ kind: LAACampaign.Kind) -> String {
        switch kind {
        case .site: "サイトの応募"
        case .x: "Xのプレゼント"
        case .grant: "助成金・補助金"
        }
    }

    /// What 「はい」 means for the kind: the routine applies, the owner applies,
    /// or the routine drafts the application.
    static func approve(_ kind: LAACampaign.Kind) -> String {
        switch kind {
        case .site: "応募させる"
        case .x: "自分で応募する"
        case .grant: "下書きを頼む"
        }
    }

    /// The quiet button on a declined row.
    static func reopen(_ kind: LAACampaign.Kind) -> String {
        kind == .grant ? "下書きを頼む" : "応募に変える"
    }

    static func approvedNote(_ kind: LAACampaign.Kind) -> String {
        switch kind {
        case .site: "次の11:00の定期実行で応募します。"
        case .x: "投稿を開いて、ご自身で応募してください。"
        case .grant: "次の定期実行で申請の下書きを作ります。"
        }
    }

    static func kind(_ kind: LAACampaign.Kind) -> String {
        switch kind {
        case .site: "サイト"
        case .x: "X"
        case .grant: "助成金"
        }
    }

    /// The deadline already heads a dated group, so a row repeats it only
    /// when it is not a day (`通年`) or the row sits under 判断済み.
    static func meta(_ item: LAACampaign, showDeadline: Bool = true) -> String {
        [kind(item.kind), item.organizer, item.benefit, showDeadline ? item.deadline.map { "締切 \($0)" } : nil,
         item.gbizid == true ? "GビズIDが必要" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Why it waits: the reason, or for an X post its entry conditions.
    static func body(_ item: LAACampaign) -> String? {
        item.reason ?? item.conditions
    }

    /// `応募させる · 11月15日（日） 17:30`: what was chosen and when.
    static func decision(_ item: LAACampaign) -> String {
        let choice = item.status == "drafted" ? "下書き済み" : item.approved ? approve(item.kind) : decline
        guard let date = LAAWorkFreshness.date(item.decidedAt) else { return choice }
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

    var waiting: [LAACampaign] { items.filter(\.waiting) }
    func waiting(_ kind: LAACampaign.Kind) -> [LAACampaign] { items.filter { $0.waiting && $0.kind == kind } }
    /// Newest choice first, so the one just made sits at the top of 判断済み.
    var decided: [LAACampaign] {
        items.filter { !$0.waiting }.sorted { ($0.decidedAt ?? "") > ($1.decidedAt ?? "") }
    }
    var count: Int { waiting.count }

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
            let page: LAACampaignPage = try await bridge.read("/v1/campaigns?kind=all")
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
        guard sending == nil else { return }
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
    func setForTesting(_ items: [LAACampaign], phase: Phase = .loaded, failures: [String: String] = [:]) {
        self.items = items; self.phase = phase; self.failures = failures
    }
    #endif
}

/// Work › Campaigns: entries the campaign-hunt routine could not decide on
/// its own, grouped by kind. Each row says what it is, why it waits, and takes
/// the owner's choice in place; chosen rows move under 判断済み and can still
/// change until the next run.
struct LAACampaignBoardView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.laaDesktop) private var laaDesktop
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var board: LAACampaignBoard
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
            LAALoadingDots().padding(20)
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
                        Button { Task { await board.load(bridge) } } label: { Text(verbatim: "再試行") }
                    }
                    .padding(.bottom, LAASpacing.x3)
                }
                if board.waiting.isEmpty {
                    sectionTitle(LAACampaignCopy.waiting, count: 0)
                    Text(verbatim: LAACampaignCopy.empty)
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        .padding(.vertical, LAASpacing.x4)
                        .accessibilityIdentifier("work.campaigns.none-waiting")
                }
                let groups = LAACampaignSchedule.groups(board.waiting)
                ForEach(groups) { group in
                    sectionTitle(group.title, count: group.items.count, urgent: group.urgent)
                        .padding(.top, group.id == groups.first?.id ? 0 : LAASpacing.x6)
                        .accessibilityIdentifier("work.campaigns.group.\(group.id)")
                    ForEach(group.items) { row($0, dated: group.id.hasPrefix("day-")) }
                }
                if !board.decided.isEmpty {
                    sectionTitle(LAACampaignCopy.decided).padding(.top, LAASpacing.x6)
                    ForEach(board.decided) { row($0) }
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

    private func sectionTitle(_ title: String, count: Int? = nil, urgent: Bool = false) -> some View {
        Text(verbatim: count.map { "\(title) \($0)" } ?? title)
            .laaTextStyle(.section).fontWeight(.semibold).monospacedDigit()
            .foregroundStyle(urgent ? LAAColor.attention : LAAColor.secondaryText)
            .padding(.bottom, LAASpacing.x1)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: LAACampaign, dated: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: item.title)
                .laaTextStyle(.body).fontWeight(.semibold)
                .foregroundStyle(item.waiting ? LAAColor.text : LAAColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            let meta = LAACampaignCopy.meta(item, showDeadline: !dated)
            if !meta.isEmpty {
                Text(verbatim: meta).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            if item.waiting, let body = LAACampaignCopy.body(item) {
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
            if item.waiting { choices(item) } else { decided(item) }
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

    private func choices(_ item: LAACampaign) -> some View {
        HStack(spacing: LAASpacing.x3) {
            choiceButton(item, approve: true)
            choiceButton(item, approve: false)
            if board.sending == item.id { LAALoadingDots() }
            Spacer(minLength: 0)
        }
    }

    private func decided(_ item: LAACampaign) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            HStack(spacing: LAASpacing.x3) {
                Label { Text(verbatim: LAACampaignCopy.decision(item)) } icon: {
                    Image(systemName: item.approved ? "checkmark.circle" : "minus.circle")
                }
                .laaTextStyle(.secondary).fontWeight(.semibold)
                .foregroundStyle(item.approved ? LAAColor.link : LAAColor.secondaryText)
                .accessibilityIdentifier("work.campaign.status.\(item.id)")
                Spacer(minLength: 0)
                // The run reads the choice at its next pass; until then it can change.
                if item.changeable {
                    Button { Task { await board.decide(item, approve: !item.approved, bridge: bridge) } } label: {
                        Text(verbatim: item.approved ? "見送りに変える" : LAACampaignCopy.reopen(item.kind))
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
                Text(verbatim: LAACampaignCopy.approvedNote(item.kind)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
        }
    }

    private func choiceButton(_ item: LAACampaign, approve: Bool) -> some View {
        Button { Task { await board.decide(item, approve: approve, bridge: bridge) } } label: {
            Text(verbatim: approve ? LAACampaignCopy.approve(item.kind) : LAACampaignCopy.decline)
                .laaTextStyle(.secondary).fontWeight(.semibold)
                .foregroundStyle(approve ? LAAColor.link : LAAColor.text)
                .padding(.horizontal, LAASpacing.x2)
        }
        .laaGlassButton()
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
                Button { Task { await board.load(bridge) } } label: { Text(verbatim: "再試行") }.laaGlassButton()
            }
        }
        .padding(LAASpacing.x8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }
}
#endif
