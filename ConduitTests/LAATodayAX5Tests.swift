#if LAA_BUILD && DEBUG && !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

final class LAATodayAX5Tests: XCTestCase {
    @MainActor func testMonthAtAX5WithAndWithoutEvents() throws {
        let selected = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 13)))
        let event = LAACalendarEvent(id: "test-review", title: "制作の打合せ", start: selected.addingTimeInterval(10 * 3600),
                                     end: selected.addingTimeInterval(11 * 3600), allDay: false, location: "オンライン")
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)

        for (name, events) in [("today-ax5", [event]), ("today-empty-ax5", [])] {
            let calendar = LAATodayCalendar(eventsForTesting: events)
            calendar.selectedDate = selected
            calendar.mode = .month
            let page = NavigationStack { LAATodayView(snapshot: calendar) }
                .environmentObject(LAABridgeSession(statusForTesting: .paired))
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .dynamicTypeSize(.accessibility5)
                .preferredColorScheme(.light)
            let host = UIHostingController(rootView: page)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
            window.traitOverrides.horizontalSizeClass = .compact
            window.traitOverrides.verticalSizeClass = .regular
            window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            host.view.layoutIfNeeded()
            XCTAssertEqual(host.traitCollection.preferredContentSizeCategory, .accessibilityExtraExtraExtraLarge)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            XCTAssertEqual(image.size, CGSize(width: 440, height: 956))
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
#endif
