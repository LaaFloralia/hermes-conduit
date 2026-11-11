#if LAA_BUILD
import Foundation
import SwiftUI
import UIKit

/// The kind of work a task belongs to, so the owner reads the list by area
/// (owner, 2026-11-11: 「ジャンル別に分けて表示」). Linear's own project and
/// labels win; most of the owner's tasks carry neither, so the title decides
/// next: its 【法人化】 or 「Work：」 prefix, then the words in it.
struct LAATaskGenre: Hashable, Identifiable {
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    /// Prefixes that only repeat the genre ("LAAアプリ：", "【法人化】"): a row
    /// in its own genre's section drops them.
    var aliases: [String] = []
    /// The order the sections stand in; Linear's own projects and labels
    /// come after the built-in genres, その他 last.
    let rank: Int

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: Built-in genres

    /// Muted tints from the LAA paper palette: each reads on the paper and the
    /// teal night, and none outshouts the row text.
    static let app = LAATaskGenre(id: "app", title: "LAAアプリ", symbol: "apps.iphone",
                                  tint: tint(0x00585E, 0x75C3C3), aliases: ["LAAアプリ", "LAA アプリ", "AIアプリ"], rank: 0)
    static let ai = LAATaskGenre(id: "ai", title: "AI・道具", symbol: "sparkles",
                                 tint: tint(0x5A4B86, 0xB8ABE3), aliases: ["AI"], rank: 1)
    static let security = LAATaskGenre(id: "security", title: "セキュリティ", symbol: "lock.shield",
                                       tint: tint(0x6C244C, 0xD49AB6), aliases: ["セキュリティ"], rank: 2)
    static let environment = LAATaskGenre(id: "environment", title: "Mac・環境", symbol: "desktopcomputer",
                                          tint: tint(0x3D5873, 0x9FBAD3), aliases: ["Mac", "環境"], rank: 3)
    static let trade = LAATaskGenre(id: "trade", title: "トレード", symbol: "chart.line.uptrend.xyaxis",
                                    tint: tint(0x86661C, 0xDCC07A), aliases: ["トレード", "取引"], rank: 4)
    static let company = LAATaskGenre(id: "company", title: "会社・法人化", symbol: "building.columns",
                                      tint: tint(0x7A5634, 0xCDA680), aliases: ["法人化", "会社"], rank: 5)
    static let creative = LAATaskGenre(id: "creative", title: "制作・発信", symbol: "paintbrush.pointed",
                                       tint: tint(0x9A4A2E, 0xE39E80), aliases: ["制作", "発信"], rank: 6)
    static let life = LAATaskGenre(id: "life", title: "学び・暮らし", symbol: "leaf",
                                   tint: tint(0x3E6B48, 0x96C7A3), aliases: ["学び", "暮らし"], rank: 7)
    static let other = LAATaskGenre(id: "other", title: "その他", symbol: "tray",
                                    tint: tint(0x66706E, 0xA8B7B4), rank: 1_000)

    static let builtIn: [LAATaskGenre] = [app, ai, security, environment, trade, company, creative, life, other]

    /// Words that settle a genre wherever they stand in the title: money,
    /// the company and safety are read first, whatever else the title names.
    private static let strong: [(LAATaskGenre, [String])] = [
        (security, ["セキュリティ", "2要素", "二要素", "パスワード", "Password", "1Password", "FileVault", "秘密",
                    "防御", "強化", "APIキー", "認証", "失効", "安全対策", "不要アカウント", "ログイン中端末", "暗号化"]),
        (company, ["法人化", "法人", "登記", "役員報酬", "名刺", "会社形態", "商号", "税務", "社会保険", "設立"]),
        (trade, ["XAU", "BTC", "トレード", "取引", "裁量", "損切", "自動売買", "FedWatch", "MyFXBook",
                 "Order Book", "相場", "MT5", "チャート"]),
    ]

    /// The rest: the genre whose word comes first in the title wins, so
    /// 「AI社員の指示書…Studioの実制作」 is AI work, not a design task.
    private static let words: [(LAATaskGenre, [String])] = [
        (app, ["LAAアプリ", "LAA Studio", "LAA Journal", "LAA Voice", "アプリ", "TestFlight", "Liquid Glass", "ウィジェット"]),
        (ai, ["AI", "Claude", "DeepSeek", "Paseo", "Venice", "Jev", "GPT", "Gemini", "Mythos", "Talos", "Monet",
              "Perplexity", "Hugging Face", "モデル", "スキル", "Skill", "エージェント", "ハーネス", "Brain", "Console",
              "自動化", "Supabase", "Agent", "DSH", "Linear"]),
        (environment, ["Mac mini", "MacBook", "Mac", "Time Machine", "SSD", "Tailscale", "Thunderbird", "空き容量",
                       "再起動", "ディスプレイ", "外付け"]),
        (creative, ["PR", "動画", "デザイン", "Studio", "制作", "写真", "HP", "SNS", "発信", "BGM", "プレイリスト",
                    "Flow", "FLUX", "ロゴ", "投稿", "映像"]),
        (life, ["有給", "休暇", "料金", "美容", "服", "サプリ", "キャリア", "時間の使い方", "学ぶ", "読み", "読む",
                "GRANDIT", "OBPM", "健康", "習慣", "買う", "購入"]),
    ]

    /// Work's sub-pages at the head of a title ("Work：", "Chat：") name the app.
    private static let appAreas: Set<String> = ["work", "chat", "chats", "doc", "ui", "today", "studio", "usage",
                                                "brain", "drive", "call", "voice", "journal", "laa"]

    /// The genre a task reads as, and the prefix that only repeats it.
    static func classify(_ task: LAALinearTask) -> LAATaskGenre {
        if let project = task.project, !project.name.isEmpty {
            return named(project.name) ?? LAATaskGenre(id: "project:\(project.id)", title: project.name, symbol: "folder",
                                                      tint: LAAColor.link, rank: 100)
        }
        for label in task.labels ?? [] where !label.name.isEmpty {
            if let known = named(label.name) { return known }
            return LAATaskGenre(id: "label:\(label.name.lowercased())", title: label.name, symbol: "tag",
                                tint: label.color.flatMap(Self.color(hex:)) ?? LAAColor.link, rank: 200)
        }
        return classify(title: task.title)
    }

    static func classify(title: String) -> LAATaskGenre {
        if let prefix = prefix(of: title) {
            if appAreas.contains(prefix.lowercased()) { return app }
            if let known = named(prefix) { return known }
        }
        for (genre, list) in strong where list.contains(where: { range(of: $0, in: title) != nil }) {
            return genre
        }
        var best: (genre: LAATaskGenre, offset: Int)?
        for (genre, list) in words {
            for word in list {
                guard let range = range(of: word, in: title) else { continue }
                let offset = title.distance(from: title.startIndex, to: range.lowerBound)
                if best == nil || offset < best!.offset { best = (genre, offset) }
            }
        }
        return best?.genre ?? other
    }

    /// Short capitals ("AI", "PR", "HP") match only as capitals, so "Email"
    /// and "Improve" stay out of them; longer words ignore case.
    private static func range(of word: String, in title: String) -> Range<String.Index>? {
        let exact = word.count <= 3 && word == word.uppercased()
        return title.range(of: word, options: exact ? [] : [.caseInsensitive])
    }

    /// A project, label or prefix that names a built-in genre: its title, an
    /// alias, or a title it reads as (project 「LAAアプリ」 → LAAアプリ).
    static func named(_ name: String) -> LAATaskGenre? {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folded.isEmpty else { return nil }
        if let exact = builtIn.first(where: { $0.title == folded || $0.aliases.contains(folded) }) { return exact }
        if appAreas.contains(folded.lowercased()) { return app }
        let genre = classify(title: folded)
        return genre == other ? nil : genre
    }

    /// 「【法人化】名刺…」 → 法人化, 「Work：エンジン…」 → Work. Nil without one.
    static func prefix(of title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("【"), let end = trimmed.firstIndex(of: "】") {
            let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<end]
            return inner.isEmpty ? nil : String(inner)
        }
        for mark in ["：", ": "] {
            if let range = trimmed.range(of: mark) {
                let head = trimmed[..<range.lowerBound]
                // A real prefix is short and a single phrase.
                if !head.isEmpty, head.count <= 14, !head.contains("、") { return String(head) }
            }
        }
        return nil
    }

    /// The title without a prefix that only repeats this genre, so the
    /// LAAアプリ section does not open every row with 「LAAアプリ：」.
    func shortTitle(_ title: String) -> String {
        guard let prefix = Self.prefix(of: title), aliases.contains(prefix) || prefix == self.title else { return title }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        var rest: Substring
        if trimmed.hasPrefix("【"), let end = trimmed.firstIndex(of: "】") {
            rest = trimmed[trimmed.index(after: end)...]
        } else if let range = trimmed.range(of: "：") ?? trimmed.range(of: ": ") {
            rest = trimmed[range.upperBound...]
        } else { return title }
        let result = rest.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? title : result
    }

    private static func tint(_ light: Int, _ dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
    }

    static func color(hex: String) -> Color? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return tint(value, value)
    }
}

/// The task list's own words: LAA text, never looked up in the catalog.
enum LAATaskBoardCopy {
    static let genre = "ジャンル"
    static let due = "期限"
    static let assignee = "担当"
    static let priority = "優先度"
    static let all = "すべて"
    static let soon = "期限が近い"
    static let attention = "要対応"
    static let ai = "AIが担当"
}

/// How the list's sections are cut. Kept on the device.
enum LAATaskGrouping: String, CaseIterable, Identifiable {
    case genre, due, assignee, priority
    static let storageKey = "laa.work.taskGrouping"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .genre: LAATaskBoardCopy.genre
        case .due: LAATaskBoardCopy.due
        case .assignee: LAATaskBoardCopy.assignee
        case .priority: LAATaskBoardCopy.priority
        }
    }
    var symbol: String {
        switch self {
        case .genre: "square.grid.2x2"
        case .due: "calendar"
        case .assignee: "person.2"
        case .priority: "chart.bar"
        }
    }
}

/// One tap narrows the list to what needs the owner now (Things' Today,
/// Linear's views). Not kept: the list always opens on everything.
enum LAATaskQuickFilter: String, CaseIterable, Identifiable {
    case all, soon, attention, ai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: LAATaskBoardCopy.all
        case .soon: LAATaskBoardCopy.soon
        case .attention: LAATaskBoardCopy.attention
        case .ai: LAATaskBoardCopy.ai
        }
    }
    func matches(_ row: LAATaskRowModel) -> Bool {
        switch self {
        case .all: true
        case .soon: row.due.map { $0.days < 3 } ?? false
        case .attention: row.needsAttention
        case .ai: row.staff != nil
        }
    }
}

/// When a task is due, in the words the row shows.
struct LAATaskDue: Equatable {
    enum Tone: Equatable { case overdue, today, soon, later }
    /// Days from today: negative is overdue.
    let days: Int
    let label: String
    var tone: Tone {
        if days < 0 { return .overdue }
        if days == 0 { return .today }
        if days < 7 { return .soon }
        return .later
    }

    static func make(_ value: String?, now: Date = Date(), calendar base: Calendar = .autoupdatingCurrent) -> LAATaskDue? {
        guard let value, let date = LAADateText.calendarDate(value) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = base.timeZone
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        guard let days = calendar.dateComponents([.day], from: today, to: day).day else { return nil }
        let label: String
        switch days {
        case 0: label = "今日"
        case 1: label = "明日"
        case ..<0: label = LAADateText.string(date, .monthDay)
        case 2..<7: label = LAADateText.string(date, .weekday) + "曜"
        default: label = LAADateText.string(date, .monthDay)
        }
        return LAATaskDue(days: days, label: label)
    }
}

/// Everything a row draws, worked out once per refresh rather than on every
/// redraw, so scrolling and hovering never re-read dates or titles.
struct LAATaskRowModel: Identifiable, Equatable {
    let task: LAALinearTask
    let genre: LAATaskGenre
    let number: String?
    let title: String
    let due: LAATaskDue?
    let staff: LAAStaff?
    let staffName: String?
    let status: LAATaskRunStatus?

    var id: String { task.id }
    var needsAttention: Bool { status?.tone == .attention || (due?.days ?? 1) < 0 }
    var completionBlocked: Bool { task.completionBlockedReason != nil }
    /// A task with a session archives it on completion: that one always asks.
    var completionAsks: Bool { task.run?.sessionId?.isEmpty == false }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.task == rhs.task && lhs.genre == rhs.genre && lhs.title == rhs.title && lhs.due == rhs.due
    }

    init(task: LAALinearTask, genre: LAATaskGenre, shortTitle: Bool, now: Date) {
        self.task = task
        self.genre = genre
        number = LAAWorkRef.display(task.ref) ?? LAAWorkRef.display(task.identifier)
        title = shortTitle ? genre.shortTitle(task.title) : task.title
        due = LAATaskDue.make(task.dueDate, now: now)
        if task.run?.assignee?.kind == "staff" {
            staff = task.run?.assignee?.staff.flatMap(LAAStaff.init(rawValue:))
            staffName = task.assigneeDisplay
        } else {
            staff = nil; staffName = nil
        }
        status = task.runStatus
    }
}

struct LAATaskSection: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String?
    let tint: Color
    /// The AI member a 担当 section belongs to, drawn as the mascot.
    let staff: LAAStaff?
    let rows: [LAATaskRowModel]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.rows == rhs.rows && lhs.title == rhs.title }
}

/// The list's sections from the loaded tasks. A pure value: the view keeps
/// the last one and rebuilds it only when an input changes.
struct LAATaskBoard: Equatable {
    struct Inputs: Equatable {
        var items: [LAALinearTask]
        var archived: Bool
        var filter: LAALinearTaskFilter
        var quick: LAATaskQuickFilter
        var query: String
        var grouping: LAATaskGrouping
        /// The calendar day the due labels were worked out on.
        var day: String
    }

    var sections: [LAATaskSection] = []
    /// Rows before the quick filter, for the chips' counts.
    var counts: [LAATaskQuickFilter: Int] = [:]
    var total: Int { sections.reduce(0) { $0 + $1.rows.count } }
    var orderedIDs: [String] { sections.flatMap { $0.rows.map(\.id) } }

    init() {}

    init(_ inputs: Inputs, now: Date = Date()) {
        let base = inputs.items
            .filter { inputs.archived ? $0.isArchived : $0.isOpen }
            .filter { inputs.archived || inputs.filter.matches($0) }
            .filter { LAAWorkRef.matches(inputs.query, ref: $0.ref, text: [$0.title, $0.description ?? "", $0.identifier]) }
            .sorted(by: Self.order)
        let shortTitles = inputs.grouping == .genre
        let models = base.map { task in
            LAATaskRowModel(task: task, genre: LAATaskGenre.classify(task), shortTitle: shortTitles, now: now)
        }
        for filter in LAATaskQuickFilter.allCases { counts[filter] = models.filter(filter.matches).count }
        let rows = models.filter(inputs.quick.matches)
        sections = Self.group(rows, by: inputs.grouping)
    }

    /// Priority first (緊急 → 低, none last), then the nearest due date, then
    /// the most recently updated: the order the list has always used.
    static func order(_ lhs: LAALinearTask, _ rhs: LAALinearTask) -> Bool {
        let a = lhs.priority == 0 ? 5 : lhs.priority
        let b = rhs.priority == 0 ? 5 : rhs.priority
        if a != b { return a < b }
        if lhs.dueDate != rhs.dueDate { return (lhs.dueDate ?? "9999") < (rhs.dueDate ?? "9999") }
        return lhs.updatedAt > rhs.updatedAt
    }

    static func group(_ rows: [LAATaskRowModel], by grouping: LAATaskGrouping) -> [LAATaskSection] {
        switch grouping {
        case .genre:
            var buckets: [LAATaskGenre: [LAATaskRowModel]] = [:]
            for row in rows { buckets[row.genre, default: []].append(row) }
            return buckets.keys.sorted { ($0.rank, $0.title) < ($1.rank, $1.title) }.map { genre in
                LAATaskSection(id: "genre:\(genre.id)", title: genre.title, symbol: genre.symbol, tint: genre.tint,
                               staff: nil, rows: buckets[genre] ?? [])
            }
        case .due:
            let order: [(String, String, String, Color, (LAATaskDue?) -> Bool)] = [
                ("overdue", "期限切れ", "exclamationmark.circle", LAAColor.attention, { ($0?.days ?? 0) < 0 }),
                ("today", "今日", "sun.max", LAAColor.attention, { $0?.days == 0 }),
                ("tomorrow", "明日", "sunrise", LAAColor.link, { $0?.days == 1 }),
                ("week", "7日以内", "calendar", LAAColor.link, { ($0?.days).map { (2..<7).contains($0) } ?? false }),
                ("later", "それ以降", "calendar.badge.clock", LAAColor.secondaryText, { ($0?.days ?? -1) >= 7 }),
                ("none", "期限なし", "tray", LAAColor.secondaryText, { $0 == nil }),
            ]
            return order.compactMap { id, title, symbol, tint, test in
                let picked = rows.filter { test($0.due) }
                return picked.isEmpty ? nil : LAATaskSection(id: "due:\(id)", title: title, symbol: symbol, tint: tint,
                                                             staff: nil, rows: picked)
            }
        case .assignee:
            var sections: [LAATaskSection] = []
            let owner = rows.filter { $0.staffName == nil }
            if !owner.isEmpty {
                sections.append(LAATaskSection(id: "assignee:owner", title: "社長", symbol: "person.crop.circle",
                                               tint: LAAColor.link, staff: nil, rows: owner))
            }
            var seen: [String] = []
            for row in rows { if let name = row.staffName, !seen.contains(name) { seen.append(name) } }
            let rank: (String) -> Int = { name in
                let staff = rows.first { $0.staffName == name }?.staff
                return staff.flatMap { LAATaskStaff.assignable.firstIndex(of: $0) } ?? 99
            }
            for name in seen.sorted(by: { (rank($0), $0) < (rank($1), $1) }) {
                let picked = rows.filter { $0.staffName == name }
                sections.append(LAATaskSection(id: "assignee:\(name)", title: name, symbol: "sparkles",
                                               tint: LAAColor.link, staff: picked.first?.staff, rows: picked))
            }
            return sections
        case .priority:
            return [1, 2, 3, 4, 0].compactMap { value in
                let picked = rows.filter { $0.task.priority == value }
                return picked.isEmpty ? nil : LAATaskSection(
                    id: "priority:\(value)", title: LAALinearTask.priorityLabel(value),
                    symbol: LAATaskPriorityGlyph.symbol(value), tint: value == 1 ? LAAColor.attention : LAAColor.link,
                    staff: nil, rows: picked)
            }
        }
    }
}

/// Linear's priority bars: 緊急 is a filled mark, 高・中・低 are three bars
/// filled from the left, 指定なし draws nothing on a row.
enum LAATaskPriorityGlyph {
    static func symbol(_ value: Int) -> String {
        value == 1 ? "exclamationmark.square.fill" : value == 0 ? "minus" : "chart.bar.fill"
    }
    static func level(_ value: Int) -> Double {
        switch value {
        case 2: 1
        case 3: 0.66
        case 4: 0.33
        default: 1
        }
    }
}

/// Which sections the owner folded, per way of grouping, kept on the device.
enum LAATaskFolding {
    static let storageKey = "laa.work.taskFolded"
    static func decode(_ raw: String) -> Set<String> { Set(raw.split(separator: "\n").map(String.init)) }
    static func encode(_ value: Set<String>) -> String { value.sorted().joined(separator: "\n") }
}
#endif
