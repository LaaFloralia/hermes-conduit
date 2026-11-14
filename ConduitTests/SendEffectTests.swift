import XCTest
import UIKit
@testable import Conduit

@MainActor
final class SendEffectTests: XCTestCase {
    func testBurstIsBoundedAndMotionReductionUsesOnlyColor() {
        let view = LAASendEffectView()
        view.frame = CGRect(x: 0, y: 0, width: 160, height: 160)
        for _ in 0..<30 { view.play(color: .systemTeal, rim: .white, reduceMotion: false) }
        XCTAssertEqual(view.layer.sublayers?.count, 1)
        // The tint, the rim light and one pane per grid square.
        XCTAssertLessThanOrEqual(view.layer.sublayers?.first?.sublayers?.count ?? 0, 2 + LAASendEffectView.cells.count)
        view.play(color: .systemTeal, rim: .white, reduceMotion: true)
        XCTAssertEqual(view.layer.sublayers?.count, 1)
        XCTAssertEqual(view.layer.sublayers?.first?.sublayers?.count, 1)
        XCTAssertFalse(view.isUserInteractionEnabled)
        view.didMoveToWindow()
        XCTAssertEqual(view.layer.sublayers?.count ?? 0, 0)
    }

    /// Short (owner's direction via the parent, 2026-11-14: refined and
    /// short) and on LAA's motion steps; the panes land on a 12 pt grid inside
    /// the effect's 160 pt square, above or level with Send.
    func testBurstIsShortAndPanesLandOnTheGrid() {
        XCTAssertEqual(LAASendEffectView.slow, 0.42, accuracy: 0.001)
        XCTAssertEqual(LAASendEffectView.quick, 0.12, accuracy: 0.001)
        XCTAssertLessThanOrEqual(LAASendEffectView.duration, 0.62 + 0.001)
        XCTAssertEqual(LAASendEffectView.cell, 12)
        XCTAssertLessThanOrEqual(LAASendEffectView.cells.count, 12)
        XCTAssertLessThanOrEqual(LAASendEffectView.lowPowerPaneCount, LAASendEffectView.cells.count)
        for cell in LAASendEffectView.cells {
            XCTAssertLessThanOrEqual(cell.y, 0, "Panes rise over the field, never below the composer")
            let reach = hypot(CGFloat(cell.x), CGFloat(cell.y)) * LAASendEffectView.cell
            XCTAssertGreaterThan(reach, 18, "A pane lands outside Send's 36 pt glass")
            XCTAssertLessThanOrEqual(reach + LAASendEffectView.cell, 80, "A pane stays inside the 160 pt overlay")
        }
        XCTAssertEqual(Set(LAASendEffectView.cells.map { "\($0.x),\($0.y)" }).count, LAASendEffectView.cells.count)
        XCTAssertEqual(LAASendEffectView.tint(dark: false).glass, 0.16, accuracy: 0.001)
        XCTAssertEqual(LAASendEffectView.tint(dark: true).glass, 0.26, accuracy: 0.001)
    }

    func testBurstFinishesAndCaptureSequence() throws {
        for dark in [false, true] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 440, height: 260)
            defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
            let host = UIViewController()
            window.rootViewController = host
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.makeKeyAndVisible()
            host.view.backgroundColor = UIColor(red: dark ? 0.059 : 0.965, green: dark ? 0.106 : 0.949, blue: dark ? 0.110 : 0.914, alpha: 1)
            let field = UITextField(frame: CGRect(x: 24, y: 100, width: 392, height: 96))
            field.text = "メッセージ"
            field.borderStyle = .roundedRect
            host.view.addSubview(field)
            let button = UIButton(type: .system)
            button.frame = CGRect(x: 366, y: 150, width: 36, height: 36)
            button.setImage(UIImage(systemName: "arrow.up"), for: .normal)
            button.tintColor = UIColor(red: dark ? 117/255 : 0, green: dark ? 195/255 : 88/255, blue: dark ? 195/255 : 94/255, alpha: 1)
            host.view.addSubview(button)
            let view = LAASendEffectView()
            view.frame = CGRect(x: 304, y: 88, width: 160, height: 160)
            host.view.addSubview(view)
            host.view.layoutIfNeeded()
            view.play(color: UIColor(red: dark ? 117/255 : 0, green: dark ? 195/255 : 88/255, blue: dark ? 195/255 : 94/255, alpha: 1),
                      rim: dark ? UIColor(red: 1, green: 253/255, blue: 248/255, alpha: 1) : UIColor(red: 185/255, green: 155/255, blue: 122/255, alpha: 1),
                      reduceMotion: false)
            CATransaction.flush()
            var previous = 0.0
            for moment in [0.04, 0.10, 0.18, 0.30, 0.44, 0.66] {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: moment - previous))
                previous = moment
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "send-\(dark ? "dark" : "light")-\(Int(moment * 1000))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            XCTAssertEqual(view.layer.sublayers?.count ?? 0, 0, "One-shot must release all layers")
            window.isHidden = true
        }
    }
}
