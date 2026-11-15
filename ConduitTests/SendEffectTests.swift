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

    /// One send plays one burst (owner, 2026-11-15: a send with the keyboard
    /// up burst at Send's old place and again at its new one). Only the
    /// first Send to hear a fresh send plays it; one that hears it again,
    /// or late after a layout change, does not.
    func testOneSendPlaysOnceAndOnlyWhileFresh() {
        let request = LAASendEffect.Request(id: UUID(), at: 100)
        XCTAssertTrue(LAASendEffectView.claim(request, now: 100.05))
        XCTAssertFalse(LAASendEffectView.claim(request, now: 100.06), "A second Send never replays the same send")
        let late = LAASendEffect.Request(id: UUID(), at: 100)
        XCTAssertFalse(LAASendEffectView.claim(late, now: 100 + LAASendEffectView.freshness + 0.01),
                       "A Send that appears after the keyboard closes does not play an earlier send")
        let next = LAASendEffect.Request(id: UUID(), at: 200)
        XCTAssertTrue(LAASendEffectView.claim(next, now: 200), "The next send plays again")
        XCTAssertTrue(ComposerBar.sendEffectPlays(for: .send))
        XCTAssertTrue(ComposerBar.sendEffectPlays(for: .interrupt), "Sending now into a running reply is a send")
        XCTAssertFalse(ComposerBar.sendEffectPlays(for: .queue))
        XCTAssertFalse(ComposerBar.sendEffectPlays(for: .steer))
    }

    /// The four ways a message goes out: keyboard up, keyboard down, sent
    /// now into a running reply, and a long draft that made the field tall.
    /// Each shows one burst, and it stays on Send as Send moves.
    func testEachWayOfSendingShowsOneBurstThatStaysOnSend() {
        struct Way { let name: String; let from: CGFloat; let to: CGFloat; let action: ComposerAction }
        let ways = [
            Way(name: "keyboard up, then closing", from: 520, to: 860, action: .send),
            Way(name: "keyboard down", from: 860, to: 860, action: .send),
            Way(name: "send now", from: 860, to: 860, action: .interrupt),
            Way(name: "long draft, field shrinking", from: 640, to: 860, action: .send),
        ]
        for way in ways {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
            window.isHidden = false
            let bar = UIView(frame: CGRect(x: 0, y: way.from, width: 440, height: 60))
            window.addSubview(bar)
            // Send in the bar at its two layouts, as SwiftUI may keep both.
            let send = LAASendEffectView()
            let other = LAASendEffectView()
            send.frame = CGRect(x: 392, y: 12, width: 36, height: 36)
            other.frame = send.frame
            bar.addSubview(send)
            bar.addSubview(other)
            let request = LAASendEffect.Request()
            XCTAssertTrue(ComposerBar.sendEffectPlays(for: way.action), way.name)
            for view in [send, other] where LAASendEffectView.claim(request) {
                view.play(color: .systemBlue, rim: .white, reduceMotion: false, lowPower: false)
            }
            // The layout settles after the send: Send moves with the bar.
            bar.frame.origin.y = way.to
            for view in [send, other] where LAASendEffectView.claim(request) {
                view.play(color: .systemBlue, rim: .white, reduceMotion: false, lowPower: false)
            }
            send.followSend()
            other.followSend()
            let bursts = window.layer.sublayers?.filter { $0.name == LAASendEffectView.burstName } ?? []
            XCTAssertEqual(bursts.count, 1, "\(way.name): one burst")
            let center = send.convert(CGPoint(x: 18, y: 18), to: window)
            XCTAssertEqual(bursts.first?.position.x ?? 0, center.x, accuracy: 0.5, way.name)
            XCTAssertEqual(bursts.first?.position.y ?? 0, center.y, accuracy: 0.5, "\(way.name): on Send, not where it was")
            send.removeFromSuperview()
            other.removeFromSuperview()
            XCTAssertFalse(window.layer.sublayers?.contains { $0.name == LAASendEffectView.burstName } ?? false)
        }
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
            XCTAssertLessThanOrEqual(pane.end.x, 0.3 * style.reach.width, "The field lies mostly to the left of Send")
            XCTAssertLessThanOrEqual(pane.end.y, 0.3 * style.reach.height, "and above it")
            XCTAssertGreaterThanOrEqual(pane.reach, reach, "Nearest first")
            reach = pane.reach
        }
        XCTAssertGreaterThan(panes.map { -$0.end.y }.max() ?? 0, style.reach.height * 0.5, "The burst spreads well above Send")
        // Restrained (owner, 2026-11-15 11時): about five times Send, never most of the screen.
        XCTAssertLessThanOrEqual(max(style.reach.width, style.reach.height), 6 * style.buttonSide)
        XCTAssertLessThan(style.duration, 0.7, "About half a second, as in the reference")
        let blue = style.color?.ui(dark: false)
        var hue: CGFloat = 0
        blue?.getHue(&hue, saturation: nil, brightness: nil, alpha: nil)
        XCTAssertEqual(hue * 360, 214, accuracy: 3, "The reference's blue, #3487F8")
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
            for moment in [0.04, 0.10, 0.16, 0.22, 0.30, 0.40, 0.50] {
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
