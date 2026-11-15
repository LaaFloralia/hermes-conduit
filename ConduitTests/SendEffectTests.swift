#if LAA_BUILD
import XCTest
import UIKit
@testable import Conduit

@MainActor
final class SendEffectTests: XCTestCase {
    func testBurstIsBoundedAndMotionReductionUsesOnlyColor() {
        let style = LAASendEffectStyle.current
        let view = LAASendEffectView()
        view.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        for _ in 0..<30 { view.play(color: .systemTeal, rim: .white, reduceMotion: false, lowPower: false) }
        XCTAssertEqual(view.layer.sublayers?.count, 1, "A second press replaces the burst")
        // The light, the tint, the rim light, the orb and one layer per pane.
        XCTAssertLessThanOrEqual(view.burst?.sublayers?.count ?? 0, 4 + style.paneCount)
        view.play(color: .systemTeal, rim: .white, reduceMotion: false, lowPower: true)
        XCTAssertLessThanOrEqual(view.burst?.sublayers?.count ?? 0, 4 + style.lowPowerPaneCount)
        view.play(color: .systemTeal, rim: .white, reduceMotion: true)
        XCTAssertEqual(view.layer.sublayers?.count, 1)
        XCTAssertEqual(view.burst?.sublayers?.count, 1, "Reduce Motion keeps only the tint")
        XCTAssertFalse(view.isUserInteractionEnabled)
        view.didMoveToWindow()
        XCTAssertEqual(view.layer.sublayers?.count ?? 0, 0)
        XCTAssertNil(view.burst)
    }

    /// Every value is the style's (owner, 2026-11-15: changing the values
    /// alone changes the look); the panes land on the grid, outside Send's
    /// glass, up and to the left within the field and the window.
    func testStyleHoldsTheValuesAndPanesLandOnTheGrid() {
        let style = LAASendEffectStyle.current
        XCTAssertLessThan(style.duration, 1.0, "Over within a second, before the thinking row settles")
        XCTAssertLessThanOrEqual(style.spreadStart + style.stagger + style.travel, style.duration)
        let panes = style.panes()
        XCTAssertEqual(panes, style.panes(), "The same send draws the same")
        XCTAssertGreaterThanOrEqual(panes.count, style.paneCount * 3 / 4)
        XCTAssertGreaterThan(style.lowPowerPaneCount, 0)
        XCTAssertLessThan(style.lowPowerPaneCount, panes.count)
        var reach = 0.0
        for pane in panes {
            XCTAssertEqual(pane.end.x.truncatingRemainder(dividingBy: style.grid), 0)
            XCTAssertEqual(pane.end.y.truncatingRemainder(dividingBy: style.grid), 0)
            XCTAssertGreaterThan(hypot(pane.end.x, pane.end.y), style.buttonSide, "Outside Send's glass")
            XCTAssertLessThanOrEqual(-pane.end.x, style.reach.width + style.grid)
            XCTAssertLessThanOrEqual(-pane.end.y, style.reach.height + style.grid)
            XCTAssertLessThanOrEqual(pane.end.x, 0.12 * style.reach.width, "The field lies to the left of Send")
            XCTAssertLessThanOrEqual(pane.end.y, 0.12 * style.reach.height, "and above it")
            XCTAssertGreaterThanOrEqual(pane.reach, reach, "Nearest first")
            reach = pane.reach
        }
        XCTAssertGreaterThan(panes.map { -$0.end.y }.max() ?? 0, style.reach.height * 0.6, "The burst reaches far up the screen")
        for pane in style.panes(limit: CGSize(width: 200, height: 300)) {
            XCTAssertLessThanOrEqual(-pane.end.x, 200 + style.grid)
            XCTAssertLessThanOrEqual(-pane.end.y, 300 + style.grid)
        }
        var fewer = style
        fewer.paneCount = 8
        XCTAssertEqual(fewer.panes().count, 8)
    }

    /// The burst on a 440 × 956 phone screen, Send at the bottom right, light
    /// and dark, at the moments the reference clip is compared at.
    func testBurstFinishesAndCaptureSequence() throws {
        let style = LAASendEffectStyle.current
        for dark in [false, true] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
            defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
            let host = UIViewController()
            window.rootViewController = host
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.makeKeyAndVisible()
            host.view.backgroundColor = UIColor(red: dark ? 0.059 : 0.965, green: dark ? 0.106 : 0.949, blue: dark ? 0.110 : 0.914, alpha: 1)
            let bubble = UILabel(frame: CGRect(x: 24, y: 520, width: 300, height: 64))
            bubble.text = "  前の返信"
            bubble.backgroundColor = dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.05)
            bubble.layer.cornerRadius = 18
            bubble.clipsToBounds = true
            host.view.addSubview(bubble)
            let field = UITextField(frame: CGRect(x: 16, y: 800, width: 408, height: 96))
            field.text = "メッセージ"
            field.borderStyle = .roundedRect
            host.view.addSubview(field)
            let button = UIButton(type: .system)
            button.frame = CGRect(x: 376, y: 852, width: 36, height: 36)
            button.setImage(UIImage(systemName: "arrow.up"), for: .normal)
            let accent = UIColor(red: dark ? 117/255 : 0, green: dark ? 195/255 : 88/255, blue: dark ? 195/255 : 94/255, alpha: 1)
            button.tintColor = accent
            host.view.addSubview(button)
            let view = LAASendEffectView()
            view.frame = button.frame
            host.view.addSubview(view)
            host.view.layoutIfNeeded()
            view.play(color: accent,
                      rim: dark ? UIColor(red: 1, green: 253/255, blue: 248/255, alpha: 1) : UIColor(red: 185/255, green: 155/255, blue: 122/255, alpha: 1),
                      reduceMotion: false, lowPower: false)
            XCTAssertTrue(view.burst?.superlayer === window.layer, "Drawn on the window, clipped by nothing")
            // Each frame at its exact moment: the window's clock is held
            // there, so a slow capture does not skew the next one.
            for moment in [0.06, 0.16, 0.28, 0.42, 0.56, 0.72, 0.88] {
                window.layer.speed = 0
                window.layer.timeOffset = view.startedAt + moment
                CATransaction.flush()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "send-\(dark ? "dark" : "light")-\(Int(moment * 1000))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            window.layer.speed = 1
            window.layer.timeOffset = 0
            CATransaction.flush()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: style.duration + 0.12))
            XCTAssertNil(view.burst, "One-shot must release all layers")
            XCTAssertFalse(window.layer.sublayers?.contains { $0.zPosition == 1000 } ?? false)
        }
    }
}
#endif
