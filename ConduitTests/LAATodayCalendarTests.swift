#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAATodayCalendarTests: XCTestCase {
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
}
#endif
