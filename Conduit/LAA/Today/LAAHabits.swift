#if LAA_BUILD
import Foundation
import Combine
import CryptoKit

struct LAAHabit: Codable, Identifiable {
    let id: String
    var kind: String
    var title: String
    var note: String
    var weeklyTarget: Int
    var minutes: Int?
    var minimum: String?
    var support: String
    let createdAt: String
    let createdOn: String
    var updatedAt: String
    var archivedAt: String?
    var archivedOn: String?
    var revision: Int
    var target: Int?
    var days: [Bool]?
    var count: Int?
    var met: Bool?
    var tally: String { Self.tally(kind: kind, count: count ?? 0, target: target ?? weeklyTarget) }
    static func tally(kind: String, count: Int, target: Int) -> String {
        "\(count) / " + (kind == "avoid" ? "\(target)まで" : "\(target)")
    }
}
struct LAAHabitWeek: Codable {
    struct Week: Codable { let start: String; let end: String; let days: [String]; let current: Bool }
    let week: Week
    let today: String
    let timeZone: String
    var items: [LAAHabit]
    let archivedCount: Int
}
struct LAAHabitItems: Decodable { let items: [LAAHabit] }
struct LAAHabitHistory: Decodable {
    struct Week: Decodable, Identifiable {
        struct Item: Decodable, Identifiable { let id: String; let kind: String; let title: String; let target: Int; let count: Int }
        let start: String; let end: String; let items: [Item]
        var id: String { start }
    }
    let weeks: [Week]
}
struct LAAHabitEvents: Decodable {
    struct Event: Decodable, Identifiable {
        let id: String; let at: String; let actor: String; let agent: String?; let type: String; let title: String
        let changes: [String: LAABridgeJSONValue]; let date: String?; let reason: String?
    }
    let items: [Event]; let nextCursor: String?
}
enum LAAHabitDates {
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Tokyo")!; c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c }
    static func date(_ text: String) -> Date { let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.date(from: text) ?? .distantPast }
    static func day(_ date: Date) -> String { let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date) }
    static func monday(_ date: Date) -> String { day(calendar.dateInterval(of: .weekOfYear, for: date)!.start) }
    static func move(_ week: String, by offset: Int) -> String { day(calendar.date(byAdding: .day, value: offset * 7, to: date(week))!) }
    static func range(_ start: String, _ end: String) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M/d（EEE）"
        return f.string(from: date(start)) + "– " + f.string(from: date(end))
    }
    static func canCheck(_ day: String, today: String, createdOn: String) -> Bool { !(today < day) && !(day < monday(date(createdOn))) }
}
enum LAAHabitCache {
    private static func url(_ key: String) -> URL? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = root.appendingPathComponent("Habits", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(digest + ".json")
    }
    static func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let url = url(key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, key: String) {
        guard let url = url(key), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
enum LAAHabitEventText {
    static func timestamp(_ text: String, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let iso = ISO8601DateFormatter(); iso.formatOptions.insert(.withFractionalSeconds)
        let date = iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        guard let date else { return "日時不明" }
        let f = DateFormatter(); f.locale = LAADateText.locale; f.timeZone = timeZone; f.dateFormat = "M/d H:mm"
        return f.string(from: date)
    }
    static func day(_ text: String) -> String {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? "\(parts[1])/\(parts[2])" : "日付不明"
    }
    static func actor(_ event: LAAHabitEvents.Event) -> String {
        event.actor == "owner" ? "社長" : (event.agent ?? "AI") + " · 理由: " + (event.reason ?? "記録なし")
    }
    static func content(_ event: LAAHabitEvents.Event) -> String {
        switch event.type {
        case "habit.created": return "追加"
        case "habit.archived": return "やめた"
        case "habit.restored": return "戻した"
        case "checkin.set": return "した" + (event.date.map { " · " + day($0) } ?? "")
        case "checkin.cleared": return "記録を外した" + (event.date.map { " · " + day($0) } ?? "")
        case "habit.updated":
            let fields = [("title", "名前"), ("weeklyTarget", "週の目標"), ("minutes", "1回の目安"), ("minimum", "最小の形"), ("support", "Monetの支援"), ("note", "メモ")]
            let changes = fields.compactMap { key, name -> String? in
                guard let change = event.changes[key] else { return nil }
                guard key != "note", case .object(let values) = change, let from = values["from"], let to = values["to"] else { return name }
                return name + ": " + value(from) + " → " + value(to)
            }
            return changes.isEmpty ? "変更" : changes.joined(separator: "、")
        default: return "記録"
        }
    }
    private static func value(_ input: LAABridgeJSONValue) -> String {
        switch input {
        case .string(let v): return ["off": "見せない", "ask": "聞いた時だけ", "plan": "提案に含める"][v] ?? v
        case .number(let v): return v.formatted()
        case .null: return "なし"
        default: return "変更"
        }
    }
}
@MainActor final class LAAHabitsModel: ObservableObject {
    @Published var selectedWeek = LAAHabitDates.monday(Date())
    @Published var value: LAAHabitWeek?
    @Published var error: String?
    @Published var loading = false
    @Published var pending: Set<String> = []
    @Published var history: [LAAHabitHistory.Week] = []
    @Published var archived: [LAAHabit] = []
    @Published var events: [LAAHabitEvents.Event] = []
    @Published var historyError: String?
    @Published var nextCursor: String?
    private var generation = 0
    private var identity: String?
    private var currentWeek = LAAHabitDates.monday(Date())
    func updateToday(now: Date = Date()) {
        let next = LAAHabitDates.monday(now)
        if selectedWeek == currentWeek { selectedWeek = next }
        currentWeek = next
    }
    func refresh(_ bridge: LAABridgeSession) async {
        updateToday()
        guard let device = bridge.deviceID, bridge.status == .paired else { error = "Macに未接続"; return }
        let key = device + ":habits:" + selectedWeek
        if identity != key { identity = key; value = LAAHabitCache.read(LAAHabitWeek.self, key: key) }
        generation += 1; let current = generation
        loading = true; error = nil
        defer { if generation == current { loading = false } }
        do {
            let result: LAABridgeResponse<LAAHabitWeek> = try await bridge.request(method: "GET", path: "/v1/habits?week=" + selectedWeek)
            guard generation == current else { return }
            value = result.data; LAAHabitCache.save(result.data, key: key)
        } catch { if generation == current { self.error = value == nil ? "習慣を読み込めません" : "習慣を読み込めません。最後に保存した内容を表示しています" } }
    }
    func toggle(_ habit: LAAHabit, index: Int, bridge: LAABridgeSession) async {
        guard let week = value, week.week.days.indices.contains(index), let days = habit.days, days.indices.contains(index),
              LAAHabitDates.canCheck(week.week.days[index], today: LAAHabitDates.day(Date()), createdOn: habit.createdOn), !pending.contains(habit.id) else { return }
        let done = !days[index]; let token = generation
        pending.insert(habit.id); error = nil
        optimistic(habit.id, index: index, done: done)
        defer { pending.remove(habit.id) }
        do {
            let _: LAABridgeResponse<LAAHabitCheckResult> = try await bridge.request(method: "PUT", path: "/v1/habits/\(habit.id)/checkins/\(week.week.days[index])", jsonBody: JSONSerialization.data(withJSONObject: ["done": done]))
            await refresh(bridge)
        } catch {
            if token == generation { optimistic(habit.id, index: index, done: !done) }
            self.error = "記録を保存できませんでした。もう一度お試しください"
        }
    }
    func optimistic(_ id: String, index: Int, done: Bool) {
        guard let i = value?.items.firstIndex(where: { $0.id == id }), var days = value?.items[i].days, days.indices.contains(index) else { return }
        days[index] = done; value?.items[i].days = days; value?.items[i].count = days.filter { $0 }.count
    }
    func loadHistory(_ bridge: LAABridgeSession, more: Bool = false) async {
        do {
            if !more {
                let h: LAABridgeResponse<LAAHabitHistory> = try await bridge.request(method: "GET", path: "/v1/habits/history?weeks=26")
                let a: LAABridgeResponse<LAAHabitItems> = try await bridge.request(method: "GET", path: "/v1/habits/archived")
                history = h.data.weeks; archived = a.data.items
            }
            let suffix = more ? "&cursor=" + (nextCursor?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") : ""
            let e: LAABridgeResponse<LAAHabitEvents> = try await bridge.request(method: "GET", path: "/v1/habits/events?limit=100" + suffix)
            events = more ? events + e.data.items : e.data.items; nextCursor = e.data.nextCursor; historyError = nil
        } catch { historyError = "履歴を読み込めません" }
    }
    func update(_ habit: LAAHabit, body: Data, bridge: LAABridgeSession) async throws -> LAAHabit {
        do {
            let result: LAABridgeResponse<LAAHabit> = try await bridge.request(method: "PATCH", path: "/v1/habits/" + habit.id, jsonBody: body, ifMatch: String(habit.revision))
            return result.data
        } catch {
            if (error as? LAABridgeHTTPError)?.status == 412 { await refresh(bridge); await loadHistory(bridge) }
            throw error
        }
    }
    func restore(_ habit: LAAHabit, bridge: LAABridgeSession) async {
        do {
            let _: LAABridgeResponse<LAAHabit> = try await bridge.request(method: "PATCH", path: "/v1/habits/" + habit.id, jsonBody: JSONSerialization.data(withJSONObject: ["archived": false]), ifMatch: String(habit.revision))
            await refresh(bridge); await loadHistory(bridge)
        } catch { await loadHistory(bridge); historyError = (error as? LAABridgeHTTPError)?.status == 412 ? "ほかで変更されました" : "習慣を戻せません" }
    }
}
struct LAAHabitCheckResult: Decodable { let habitId: String; let date: String; let done: Bool }
#endif
