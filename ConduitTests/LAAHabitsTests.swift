#if LAA_BUILD
import XCTest
import SwiftUI
import UIKit
@testable import Conduit

private final class HabitProtocol: URLProtocol {
    nonisolated(unsafe) static var replies: [(Int, Data)] = []
    nonisolated(unsafe) static var paths: [String] = []
    nonisolated(unsafe) static var onRequest: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.paths.append(request.url!.path); Self.onRequest?()
        let reply = Self.replies.isEmpty ? (503, Data()) : Self.replies.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.1); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor final class LAAHabitsTests: XCTestCase {
    static func fixture(empty: Bool = false) -> LAAHabitWeek {
        let item = LAAHabit(id: "walk", kind: "do", title: "散歩", note: "", weeklyTarget: 3, minutes: 20, minimum: "外に出る", support: "ask", createdAt: "2026-11-09T00:00:00Z", createdOn: "2026-11-09", updatedAt: "2026-11-09T00:00:00Z", revision: 1, target: 3, days: [true, false, true, false, false, false, false], count: 2, met: false)
        var avoid = item; avoid.kind = "avoid"; avoid.title = "夜更かし"; avoid.weeklyTarget = 0; avoid.target = 0
        return LAAHabitWeek(week: .init(start: "2026-11-09", end: "2026-11-15", days: (9...15).map { "2026-11-\($0 < 10 ? "0" : "")\($0)" }, current: true), today: "2026-11-14", timeZone: "Asia/Tokyo", items: empty ? [] : [item, avoid], archivedCount: 0)
    }
    private func bridge() -> LAABridgeSession {
        HabitProtocol.paths = []; HabitProtocol.replies = []; HabitProtocol.onRequest = nil
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HabitProtocol.self]
        let credentials = LAABridgeCredentials(baseURL: URL(string: "http://127.0.0.1:9")!, deviceID: UUID().uuidString, token: "fixture")
        return LAABridgeSession(client: LAABridgeClient(session: URLSession(configuration: config)), readCredentials: { credentials })
    }
    func testDecode() throws {
        let data = try JSONEncoder().encode(Self.fixture())
        let week = try JSONDecoder().decode(LAAHabitWeek.self, from: data)
        XCTAssertEqual(week.items[0].tally, "2 / 3"); XCTAssertEqual(week.items[1].tally, "2 / 0まで")
        XCTAssertEqual(week.week.days.count, 7)
    }
    func testHistoryTextHidesInternalChanges() {
        func event(_ type: String, _ changes: [String: LAABridgeJSONValue] = [:]) -> LAAHabitEvents.Event {
            .init(id: "event", at: "2026-11-14T10:41:00.000Z", actor: "agent", agent: "Monet", type: type, title: "散歩", changes: changes, date: "2026-11-14", reason: "社長の依頼で週の目標を変更")
        }
        let changes: [String: LAABridgeJSONValue] = ["note": .object(["fromLength": .number(1), "toLength": .number(2)]), "kind": .string("do"), "archived": .bool(true)]
        XCTAssertEqual(LAAHabitEventText.content(event("habit.created", changes)), "追加")
        XCTAssertEqual(LAAHabitEventText.content(event("habit.updated", changes)), "メモ")
        XCTAssertEqual(LAAHabitEventText.content(event("checkin.set", changes)), "した · 11/14")
        XCTAssertEqual(LAAHabitEventText.content(event("checkin.cleared", changes)), "記録を外した · 11/14")
        XCTAssertEqual(LAAHabitEventText.timestamp(event("habit.created").at, timeZone: TimeZone(identifier: "Asia/Tokyo")!), "11/14 19:41")
        XCTAssertEqual(LAAHabitEventText.actor(event("habit.updated")), "Monet · 理由: 社長の依頼で週の目標を変更")
    }
    func testTokyoWeekAndRange() {
        XCTAssertEqual(LAAHabitDates.monday(LAAHabitDates.date("2026-11-15")), "2026-11-09")
        XCTAssertEqual(LAAHabitDates.move("2026-11-09", by: -1), "2026-11-02")
        XCTAssertEqual(LAAHabitDates.move("2026-12-28", by: 1), "2027-01-04")
        XCTAssertEqual(LAAHabitDates.range("2026-11-09", "2026-11-15"), "11/9（月）– 11/15（日）")
    }
    func testWeekRolloverPreservesBrowsedWeek() {
        let model = LAAHabitsModel()
        let next = LAAHabitDates.move(model.selectedWeek, by: 1)
        model.updateToday(now: LAAHabitDates.date(next)); XCTAssertEqual(model.selectedWeek, next)
        model.selectedWeek = "2026-11-02"
        model.updateToday(now: LAAHabitDates.date(LAAHabitDates.move(next, by: 1)))
        XCTAssertEqual(model.selectedWeek, "2026-11-02")
    }
    func testCheckableDays() {
        XCTAssertTrue(LAAHabitDates.canCheck("2026-11-09", today: "2026-11-14", createdOn: "2026-11-14"))
        XCTAssertFalse(LAAHabitDates.canCheck("2026-11-08", today: "2026-11-14", createdOn: "2026-11-14"))
        XCTAssertFalse(LAAHabitDates.canCheck("2026-11-15", today: "2026-11-14", createdOn: "2026-11-09"))
    }
    func testOptimisticFailureRollsBack() async {
        let b = bridge(); let m = LAAHabitsModel(); m.value = Self.fixture()
        await m.toggle(m.value!.items[0], index: 0, bridge: b)
        XCTAssertEqual(m.value!.items[0].count, 2); XCTAssertEqual(m.value!.items[0].days?[0], true)
        XCTAssertNotNil(m.error); XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(HabitProtocol.paths, ["/v1/habits/walk/checkins/2026-11-09"])
    }
    func testOptimisticCount() {
        let m = LAAHabitsModel(); m.value = Self.fixture()
        m.optimistic("walk", index: 1, done: true); XCTAssertEqual(m.value!.items[0].count, 3)
        m.optimistic("walk", index: 1, done: false); XCTAssertEqual(m.value!.items[0].count, 2)
    }
    func testConflictReloadsWeekAndHistory() async throws {
        let b = bridge(); let m = LAAHabitsModel()
        let envelope = try JSONSerialization.data(withJSONObject: ["data": ["weeks": []], "requestId": "fixture"])
        let items = try JSONSerialization.data(withJSONObject: ["data": ["items": []], "requestId": "fixture"])
        let event = try JSONSerialization.data(withJSONObject: ["data": ["items": [], "nextCursor": NSNull()], "requestId": "fixture"])
        let week = try JSONSerialization.data(withJSONObject: ["data": JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.fixture())), "requestId": "fixture"])
        HabitProtocol.replies = [(412, Data()), (200, week), (200, envelope), (200, items), (200, event)]
        do { _ = try await m.update(Self.fixture().items[0], body: Data("{}".utf8), bridge: b); XCTFail("Expected conflict") } catch { XCTAssertEqual((error as? LAABridgeHTTPError)?.status, 412) }
        XCTAssertNotNil(m.value); XCTAssertEqual(HabitProtocol.paths.count, 5)
    }
    func testHabitsNeverRequestsCalendar() async {
        let b = bridge(); let c = LAATodayCalendar(); c.mode = .habits
        await c.refresh(bridge: b); XCTAssertTrue(HabitProtocol.paths.isEmpty)
    }
    func testCachedWeekSurvivesFailure() async throws {
        let b = bridge(); let m = LAAHabitsModel()
        LAAHabitCache.save(Self.fixture(), key: b.deviceID! + ":habits:" + m.selectedWeek)
        await m.refresh(b); XCTAssertEqual(m.value?.items.count, 2); XCTAssertNotNil(m.error)
    }
}
@MainActor final class LAAHabitsSnapshotTests: XCTestCase {
    func testLightAndDarkStates() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for state in ["habits", "empty", "failure", "create", "edit", "history"] { try render(style, state: state) }
        }
    }
    private func render(_ style: UIUserInterfaceStyle, state: String) throws {
        let model = LAAHabitsModel(); model.selectedWeek = "2026-11-09"; model.value = LAAHabitsTests.fixture(empty: state == "empty")
        if state == "failure" { model.error = "習慣を読み込めません。最後に保存した内容を表示しています" }
        let bridge = LAABridgeSession(statusForTesting: .paired)
        model.history = [
            .init(start: "2026-11-02", end: "2026-11-08", items: [.init(id: "walk", kind: "do", title: "散歩", target: 3, count: 2), .init(id: "night", kind: "avoid", title: "夜更かし", target: 2, count: 1)]),
            .init(start: "2026-10-26", end: "2026-11-01", items: [.init(id: "walk", kind: "do", title: "散歩", target: 3, count: 3)])
        ]
        var archived = LAAHabitsTests.fixture().items[0]; archived.title = "読書"; archived.archivedAt = "2026-11-14T10:00:00Z"; model.archived = [archived]
        model.events = [
            .init(id: "owner", at: "2026-11-14T10:41:00Z", actor: "owner", agent: nil, type: "habit.created", title: "散歩", changes: ["kind": .string("do")], date: nil, reason: nil),
            .init(id: "monet", at: "2026-11-14T10:40:00Z", actor: "agent", agent: "Monet", type: "habit.updated", title: "散歩", changes: ["weeklyTarget": .object(["from": .number(3), "to": .number(2)])], date: nil, reason: "今週の予定に合わせて負担を減らす")
        ]
        let view = screen(model, state: state)
            .environmentObject(bridge).preferredColorScheme(style == .dark ? .dark : .light)
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        window.traitOverrides.horizontalSizeClass = .compact; window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKeyAndVisible() }
        host.view.layoutIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        if state == "edit" {
            func scrollToBottom(_ view: UIView) {
                if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
                    scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                }
                for child in view.subviews { scrollToBottom(child) }
            }
            scrollToBottom(window); window.layoutIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertEqual(image.size, CGSize(width: 440, height: 956))
        let name = "habits-\(state)-\(style == .dark ? "dark" : "light")"
        let a = XCTAttachment(image: image); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    @ViewBuilder private func screen(_ model: LAAHabitsModel, state: String) -> some View {
        if state == "history" {
            NavigationStack {
                ScrollView { LAAHabitsHistoryView(model: model, automaticallyRefresh: false).padding(LAASpacing.horizontal) }
                    .background(LAAColor.background).navigationTitle(Text(verbatim: "履歴")).navigationBarTitleDisplayMode(.inline)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.section) {
                    LAATabHeading(title: "Today", identifier: "laa.today.title")
                    LAASegmentedControl(values: LAACalendarMode.visibleModes, selection: .constant(.habits), title: \.title)
                    LAAHabitsView(model: model, showCreate: .constant(false), connect: {}, automaticallyRefresh: false)
                }.padding(LAASpacing.horizontal)
            }.background(LAAColor.background)
                .sheet(isPresented: .constant(state == "create" || state == "edit")) {
                    LAAHabitEditor(habit: state == "edit" ? model.value?.items.first : nil, model: model).laaSheetSize(.form)
                }
        }
    }

}
#endif
