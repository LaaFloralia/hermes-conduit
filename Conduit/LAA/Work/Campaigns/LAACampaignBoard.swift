#if LAA_BUILD
import Foundation
import SwiftUI

/// One campaign entry from `GET /v1/campaigns`. The Bridge passes on the
/// campaign-hunt ledger's rows; personal details never reach the ledger.
struct LAACampaign: Codable, Equatable, Identifiable, Sendable {
    let key: String
    let status: String
    let title: String
    let organizer: String?
    let prize: String?
    let deadline: String?
    let reason: String?
    let conditions: String?
    let url: String
    let at: String?
    let decidedAt: String?

    var id: String { key }
    var waiting: Bool { status == "needs_owner" }
    var approved: Bool { status == "approved" }

    func with(status: String, decidedAt: String?) -> LAACampaign {
        LAACampaign(key: key, status: status, title: title, organizer: organizer, prize: prize, deadline: deadline,
                    reason: reason, conditions: conditions, url: url, at: at, decidedAt: decidedAt)
    }
}

struct LAACampaignPage: Decodable, Sendable {
    let count: Int
    let items: [LAACampaign]
}

struct LAACampaignDecision: Decodable, Sendable {
    let key: String
    let status: String
    let decidedAt: String?
}

enum LAACampaignCopy {
    static let section = "Campaigns"
    static let heading = "応募の判断"
    static let waiting = "判断待ち"
    static let decided = "判断済み"
    static let approve = "応募させる"
    static let decline = "見送る"
    static let open = "ページを開く"
    static let empty = "判断待ちの応募はありません"
    static let unsupported = "Macのアップデート待ちです"
    static let unsupportedDetail = "MacのLAA Bridgeを更新すると、応募の判断を表示します。"
    static let approvedNote = "次の11:00の定期実行で応募します。"

    static func meta(_ item: LAACampaign) -> String {
        [item.organizer, item.prize.map { "賞品 \($0)" }, item.deadline.map { "締切 \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// `応募させる · 11/15 17:30`: what was chosen and when.
    static func decision(_ item: LAACampaign) -> String {
        let choice = item.approved ? approve : decline
        guard let date = LAAWorkFreshness.date(item.decidedAt) else { return choice }
        return choice + " · " + LAADateText.string(date, .dayTime)
    }

    static func error(_ error: Error) -> String {
        if let error = error as? LAABridgeHTTPError {
            switch error.code {
            case "campaign_not_found": return "この応募は台帳に見つかりません。読み直してください。"
            case "campaign_not_pending": return "この応募はすでに処理されています。読み直してください。"
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
            let page: LAACampaignPage = try await bridge.read("/v1/campaigns")
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
        struct Body: Encodable { let choice: String }
        sending = item.key
        failures[item.key] = nil
        defer { sending = nil }
        do {
            let body = try JSONEncoder().encode(Body(choice: approve ? "approve" : "decline"))
            let result: LAACampaignDecision = try await LAAWorkHTTP.write(
                bridge, path: "/v1/campaigns/\(item.key)/decide", body: body, key: LAABridgeIdempotencyKey())
            if let index = items.firstIndex(where: { $0.key == result.key }) {
                items[index] = items[index].with(status: result.status, decidedAt: result.decidedAt)
            }
        } catch is CancellationError {
        } catch {
            failures[item.key] = LAACampaignCopy.error(error)
        }
    }

    #if DEBUG
    func setForTesting(_ items: [LAACampaign], phase: Phase = .loaded, failures: [String: String] = [:]) {
        self.items = items; self.phase = phase; self.failures = failures
    }
    #endif
}

/// Work › Campaigns: entries the campaign-hunt routine could not decide on
/// its own. Each row says what it is, why it waits, and takes the owner's
/// choice in place; chosen rows move under 判断済み and can still change
/// until the next run.
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
                sectionTitle(LAACampaignCopy.waiting, count: board.waiting.count)
                if board.waiting.isEmpty {
                    Text(verbatim: LAACampaignCopy.empty)
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        .padding(.vertical, LAASpacing.x4)
                        .accessibilityIdentifier("work.campaigns.none-waiting")
                }
                ForEach(board.waiting) { row($0) }
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

    private func sectionTitle(_ title: String, count: Int? = nil) -> some View {
        Text(verbatim: count.map { "\(title) \($0)" } ?? title)
            .laaTextStyle(.section).fontWeight(.semibold).monospacedDigit()
            .foregroundStyle(LAAColor.secondaryText)
            .padding(.bottom, LAASpacing.x1)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: LAACampaign) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: item.title)
                .laaTextStyle(.body).fontWeight(.semibold)
                .foregroundStyle(item.waiting ? LAAColor.text : LAAColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            let meta = LAACampaignCopy.meta(item)
            if !meta.isEmpty {
                Text(verbatim: meta).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            if item.waiting, let reason = item.reason {
                Text(verbatim: reason).laaTextStyle(.secondary).foregroundStyle(LAAColor.text)
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
            .accessibilityIdentifier("work.campaign.open.\(item.key)")
            if item.waiting { choices(item) } else { decided(item) }
            if let failure = board.failures[item.key] {
                Text(verbatim: failure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    .accessibilityIdentifier("work.campaign.failure.\(item.key)")
            }
        }
        .padding(.vertical, LAASpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(LAAColor.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.campaign.\(item.key)")
    }

    private func choices(_ item: LAACampaign) -> some View {
        HStack(spacing: LAASpacing.x3) {
            choiceButton(item, approve: true)
            choiceButton(item, approve: false)
            if board.sending == item.key { LAALoadingDots() }
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
                .accessibilityIdentifier("work.campaign.status.\(item.key)")
                Spacer(minLength: 0)
                // The run reads the choice at 11:00; until then it can change.
                Button { Task { await board.decide(item, approve: !item.approved, bridge: bridge) } } label: {
                    Text(verbatim: item.approved ? "見送りに変える" : "応募に変える")
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                        .frame(minHeight: LAASpacing.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(board.sending != nil)
                .accessibilityIdentifier("work.campaign.change.\(item.key)")
            }
            if item.approved {
                Text(verbatim: LAACampaignCopy.approvedNote).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
        }
    }

    private func choiceButton(_ item: LAACampaign, approve: Bool) -> some View {
        Button { Task { await board.decide(item, approve: approve, bridge: bridge) } } label: {
            Text(verbatim: approve ? LAACampaignCopy.approve : LAACampaignCopy.decline)
                .laaTextStyle(.secondary).fontWeight(.semibold)
                .foregroundStyle(approve ? LAAColor.link : LAAColor.text)
                .padding(.horizontal, LAASpacing.x2)
        }
        .laaGlassButton()
        .disabled(board.sending != nil)
        .accessibilityIdentifier("work.campaign.\(approve ? "approve" : "decline").\(item.key)")
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
