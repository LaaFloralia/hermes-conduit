#if LAA_BUILD
import XCTest
import SwiftUI
@testable import Conduit

final class LAATodayCalendarTests: XCTestCase {
    func testAgendaKeepsTodayAndOnlyFutureDaysWithEvents() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11))!
        let future = calendar.date(byAdding: .day, value: 3, to: today)!
        let event = LAACalendarEvent(id: "later", title: "予定", start: future,
                                     end: future.addingTimeInterval(3600), allDay: false, location: nil)
        XCTAssertEqual(LAACalendarMode.agendaDays(events: [event], now: today, calendar: calendar), [today, future])
        XCTAssertEqual(LAACalendarMode.agendaDays(events: [], now: today, calendar: calendar), [today])
        XCTAssertEqual(LAACalendarMode.visibleModes, [.list, .week, .month])
    }

    @MainActor func testMidnightFollowsTodayAndPreservesBrowsedMonth() {
        let state = LAATodayCalendar()
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        state.selectedDate = today
        XCTAssertTrue(state.updateToday(now: tomorrow))
        XCTAssertEqual(state.selectedDate, tomorrow)
        XCTAssertFalse(state.updateToday(now: tomorrow.addingTimeInterval(3600)))
        state.mode = .month
        let past = Calendar.current.date(byAdding: .month, value: -1, to: today)!
        state.selectedDate = past
        XCTAssertTrue(state.updateToday(now: Calendar.current.date(byAdding: .day, value: 2, to: today)!))
        XCTAssertEqual(state.selectedDate, past)
    }

    func testCalendarEventPathStrictlyEncodesOpaqueIDs() throws {
        for id in ["invite@host", "part#name", "a+b", "a_b", "all@#+_/?%"] {
            let path = try LAACalendarRequest.eventPath(id: id, calendarID: id)
            let parts = try XCTUnwrap(URLComponents(string: path))
            let segment = String(parts.percentEncodedPath.dropFirst("/v1/calendar/events/".count))
            XCTAssertEqual(segment.removingPercentEncoding, id)
            XCTAssertFalse(segment.contains(where: { "/?# +@".contains($0) }))
            XCTAssertEqual(parts.queryItems?.first?.value, id)
            XCTAssertNil(parts.fragment)
            XCTAssertEqual(try LAACalendarRequest.eventPath(id: id), "/v1/calendar/events/" + segment)
        }
        for id in ["", String(repeating: "a", count: 1025)] {
            XCTAssertThrowsError(try LAACalendarRequest.eventPath(id: id))
            XCTAssertThrowsError(try LAACalendarRequest.eventPath(id: "valid", calendarID: id))
        }
    }

    func testEventsOverlappingMidnightAppearOnBothDays() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let event = LAACalendarEvent(id: "night", title: "Night", start: day.addingTimeInterval(-3600),
                                     end: day.addingTimeInterval(3600), allDay: false, location: nil)
        XCTAssertTrue(event.overlaps(start: day.addingTimeInterval(-86400), end: day))
        XCTAssertTrue(event.overlaps(start: day, end: day.addingTimeInterval(86400)))
        XCTAssertFalse(event.overlaps(start: event.end, end: event.end.addingTimeInterval(86400)))
    }
    func testSnapshotRoundTripPreservesCalendarFields() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = LAACalendarEvent(id: "event", title: "Meeting", start: now,
                                     end: now.addingTimeInterval(3600), allDay: false, location: "Office")
        let decoded = try JSONDecoder().decode([LAACalendarEvent].self, from: JSONEncoder().encode([event]))
        XCTAssertEqual(decoded.first?.id, "event")
        XCTAssertEqual(decoded.first?.start, now)
        XCTAssertEqual(decoded.first?.location, "Office")
    }
    func testGoogleAllDayUsesLocalMidnightAndExclusiveEnd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let event = LAACalendarResponse.Event(id: "day", title: "連休", start: "2026-11-02", end: "2026-11-04", allDay: true, location: nil)
        let value = try event.value(calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: value.start), 0)
        XCTAssertEqual(value.end.timeIntervalSince(value.start), 2 * 86400)
        XCTAssertFalse(value.overlaps(start: value.end, end: value.end.addingTimeInterval(86400)))
    }

    func testGoogleTimedEventsDecodeFractionalSecondsAndOffsets() throws {
        let event = LAACalendarResponse.Event(id: "timed", title: "打合せ", start: "2026-11-02T10:00:00.123+09:00",
            end: "2026-11-02T02:00:00.123Z", allDay: false, location: "会議室")
        let value = try event.value()
        XCTAssertEqual(value.end.timeIntervalSince(value.start), 3600, accuracy: 0.01)
        XCTAssertEqual(value.location, "会議室")
    }

    func testMalformedGoogleDatesAreRejected() {
        for date in ["bad", "2026-02-30"] {
            let event = LAACalendarResponse.Event(id: "bad", title: "Bad", start: date, end: "2026-11-04", allDay: true, location: nil)
            XCTAssertThrowsError(try event.value())
        }
    }

    @MainActor func testRequestIncludesSevenLocalDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12))!
        let path = LAATodayCalendar.requestPath(now: now, calendar: calendar)
        let items = try XCTUnwrap(URLComponents(string: path)?.queryItems)
        let formatter = ISO8601DateFormatter()
        let start = try XCTUnwrap(formatter.date(from: items.first { $0.name == "start" }!.value!))
        let end = try XCTUnwrap(formatter.date(from: items.first { $0.name == "end" }!.value!))
        XCTAssertEqual(calendar.component(.hour, from: start), 0)
        XCTAssertEqual(calendar.component(.hour, from: end), 0)
        XCTAssertEqual(end.timeIntervalSince(start), 7 * 86400 + 3600)
    }

    @MainActor func testUnpairedNeverReportsAnEmptyCalendar() async {
        let state = LAATodayCalendar()
        await state.refresh(bridge: LAABridgeSession(statusForTesting: .unpaired))
        XCTAssertFalse(state.loaded)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.errorMessage?.contains("Mac") == true)
    }

    @MainActor func testConnectionErrorsHaveDistinctActionableCopy() {
        let codes = ["calendar_not_configured", "calendar_auth_required", "calendar_access_denied", "calendar_not_found"]
        let messages = codes.map { code in
            LAATodayCalendar.message(for: LAABridgeHTTPError(status: 503, code: code, message: "secret upstream detail",
                retryable: false, details: nil, requestId: nil, currentETag: nil))
        }
        XCTAssertEqual(Set(messages).count, codes.count)
        XCTAssertFalse(messages.joined().contains("secret"))
    }

    func testWidgetSnapshotExpiresWithoutPretendingThereAreNoEvents() {
        let now = Date()
        let snapshot = LAACalendarSnapshot(updatedAt: now, events: [])
        XCTAssertTrue(snapshot.isFresh(at: now.addingTimeInterval(3599)))
        XCTAssertFalse(snapshot.isFresh(at: now.addingTimeInterval(3600)))
        XCTAssertFalse(snapshot.isFresh(at: now.addingTimeInterval(-1)))
    }

    @MainActor func testSuccessfulReadThenFailureKeepsSavedEventsWithFailureReason() async {
        let state = LAATodayCalendar()
        await state.refresh(isPaired: true) {
            LAACalendarResponse(items: [.init(id: "one", title: "打合せ", start: "2026-11-02T10:00:00+09:00",
                end: "2026-11-02T11:00:00+09:00", allDay: false, location: "オンライン")])
        }
        XCTAssertTrue(state.loaded)
        XCTAssertEqual(state.events.first?.title, "打合せ")
        await state.refresh(isPaired: true) { throw URLError(.notConnectedToInternet) }
        XCTAssertTrue(state.loaded)
        XCTAssertEqual(state.events.first?.title, "打合せ")
        XCTAssertNotNil(state.errorMessage)
    }

    @MainActor func testOlderReadCannotRepopulateAfterUnpairing() async {
        let state = LAATodayCalendar()
        let started = expectation(description: "older request started")
        let oldRead = Task { @MainActor in
            await state.refresh(isPaired: true) {
                started.fulfill()
                try await Task.sleep(for: .milliseconds(80))
                return LAACalendarResponse(items: [])
            }
        }
        await fulfillment(of: [started], timeout: 1)
        await state.refresh(isPaired: false) { XCTFail("Unpaired state must not fetch"); return LAACalendarResponse(items: []) }
        await oldRead.value
        XCTAssertFalse(state.loaded)
        XCTAssertNotNil(state.errorMessage)
    }

    func testSwitchingToAllDayPreservesAnExclusiveNextDayEndAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 10))!
        let range = LAACalendarDates.allDayRange(start: start, end: start.addingTimeInterval(3600), calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: range.start), 0)
        XCTAssertEqual(calendar.component(.day, from: range.end), 2)
        XCTAssertEqual(calendar.component(.hour, from: range.end), 0)
        XCTAssertEqual(range.duration, 25 * 3600)
    }

    func testCalendarModesUseLocalDayBoundariesAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        for mode in LAACalendarMode.allCases {
            let range = mode.range(containing: date, calendar: calendar)
            XCTAssertEqual(calendar.component(.hour, from: range.start), 0)
            XCTAssertEqual(calendar.component(.hour, from: range.end), 0)
            XCTAssertTrue(range.contains(date))
            let days = calendar.dateComponents([.day], from: range.start, to: range.end).day
            XCTAssertEqual(days, mode == .month ? 42 : mode == .day ? 1 : 7)
        }
    }

    func testIdenticalEventIDsInDifferentCalendarsRemainDistinctAndKeepDetail() throws {
        let source = #"{"items":[{"id":"same","calendarId":"one+team@example.com","title":"Meeting","start":"2026-11-02T01:00:00Z","end":"2026-11-02T02:00:00Z","allDay":false,"description":"Notes","etag":"version","attendees":[{"email":"guest@example.com","name":"Guest","response":"accepted"}],"attachments":[{"title":"Brief","url":"https://example.com/brief"}],"recurrence":["RRULE:FREQ=WEEKLY"]},{"id":"same","calendarId":"two@example.com","title":"Other","start":"2026-11-02T01:00:00Z","end":"2026-11-02T02:00:00Z","allDay":false}]}"#
        let decoded = try JSONDecoder().decode(LAACalendarResponse.self, from: Data(source.utf8))
        let values = try decoded.items.map { try $0.value() }
        XCTAssertEqual(Set(values.map(\.id)).count, 2)
        let stored = try JSONDecoder().decode([LAACalendarEvent].self, from: JSONEncoder().encode(values))
        XCTAssertEqual(stored.first?.calendarId, "one+team@example.com")
        XCTAssertEqual(stored.first?.notes, "Notes")
        XCTAssertEqual(stored.first?.attendees?.first?.response, "accepted")
        XCTAssertEqual(stored.first?.attachments?.first?.title, "Brief")
        XCTAssertEqual(stored.first?.recurrence, ["RRULE:FREQ=WEEKLY"])
    }

    @MainActor func testTodaySnapshotsAtOwnerSize() throws {
        let today = Calendar.current.startOfDay(for: Date())
        var samples = [
            LAACalendarEvent(id: "meeting", title: "制作の打合せ", start: today.addingTimeInterval(10 * 3600),
                end: today.addingTimeInterval(11 * 3600), allDay: false, location: "オンライン"),
            LAACalendarEvent(id: "visit", title: "展示会", start: today.addingTimeInterval(86400),
                end: today.addingTimeInterval(2 * 86400), allDay: true, location: "東京")
        ]
        samples[0].googleID = "meeting"; samples[0].calendarId = "work@example.com"; samples[0].etag = "version"
        samples[0].notes = "新しい展示と制作の進め方を確認します。"
        samples[0].meetingLink = "https://meet.google.com/abc-defg-hij"
        samples[0].attendees = [.init(email: "guest@example.com", name: "参加者", response: "accepted")]
        let calendars = [LAAGoogleCalendar(id: "work@example.com", title: "仕事", color: "#1a73e8", selected: true, writable: true)]
        let month = LAATodayCalendar(eventsForTesting: samples, calendarsForTesting: calendars); month.mode = .month
        let states: [(String, LAATodayCalendar)] = [
            ("month", month),
            ("events", LAATodayCalendar(eventsForTesting: samples, calendarsForTesting: calendars)),
            ("empty", LAATodayCalendar(eventsForTesting: [])),
            ("not-configured", LAATodayCalendar(errorForTesting: "Googleカレンダーは未連携です。Mac側の連携設定が必要です。")),
            ("offline", LAATodayCalendar(errorForTesting: "予定を取得できませんでした。Macとネットワークの接続を確認し、再読み込みしてください。"))
        ]
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let insets = previous?.safeAreaInsets ?? .zero
        var views = states.map { ($0.0, AnyView(LAATodayView(snapshot: $0.1))) }
        views += [("detail", AnyView(LAACalendarDetail(event: samples[0], calendars: calendars, changed: {}))),
                  ("editor", AnyView(LAACalendarEditor(event: samples[0], calendars: calendars, date: today, saved: {})))]
        for (name, view) in views {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let host = UIHostingController(rootView: NavigationStack { view }
                    .environmentObject(LAABridgeSession(statusForTesting: .paired))
                    .environment(\.locale, Locale(identifier: "ja_JP"))
                    .preferredColorScheme(style == .dark ? .dark : .light))
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 440 + insets.left + insets.right, height: 956)
                window.traitOverrides.horizontalSizeClass = .compact
                window.traitOverrides.userInterfaceStyle = style
                window.rootViewController = host
                window.makeKeyAndVisible()
                defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                host.view.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = true
                let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let crop = CGRect(x: host.view.safeAreaInsets.left * 3, y: 0, width: 1320, height: 2868)
                let cgImage = try XCTUnwrap(rendered.cgImage?.cropping(to: crop))
                let image = UIImage(cgImage: cgImage, scale: 3, orientation: .up)
                XCTAssertEqual(image.size, CGSize(width: 440, height: 956))
                let attachment = XCTAttachment(image: image)
                attachment.name = "today-google-\(name)-\(style == .dark ? "dark" : "light")-440x956"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

}
#endif
