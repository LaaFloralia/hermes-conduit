import XCTest
import UIKit
import SwiftUI
@testable import Conduit

@MainActor
final class SendEffectTests: XCTestCase {
    func testBurstIsBoundedAndMotionReductionUsesOnlyColor() {
        let view = LAASendEffectView()
        view.frame = CGRect(x: 0, y: 0, width: 160, height: 160)
        for _ in 0..<30 { view.play(color: .systemTeal, reduceMotion: false) }
        XCTAssertEqual(view.layer.sublayers?.count, 1)
        XCTAssertLessThanOrEqual(view.layer.sublayers?.first?.sublayers?.count ?? 0, 21)
        view.play(color: .systemTeal, reduceMotion: true)
        XCTAssertEqual(view.layer.sublayers?.count, 1)
        XCTAssertEqual(view.layer.sublayers?.first?.sublayers?.count, 1)
        XCTAssertFalse(view.isUserInteractionEnabled)
        view.didMoveToWindow()
        XCTAssertEqual(view.layer.sublayers?.count ?? 0, 0)
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
            host.view.addSubview(button)
            let view = LAASendEffectView()
            view.frame = CGRect(x: 304, y: 88, width: 160, height: 160)
            host.view.addSubview(view)
            host.view.layoutIfNeeded()
            view.play(color: UIColor(Color.conduitAccent), reduceMotion: false)
            var previous = 0.0
            for moment in [0.04, 0.16, 0.32, 0.56, 0.86] {
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
            XCTAssertEqual(view.layer.sublayers?.count ?? 0, 0, "One-shot must release all layers")
            window.isHidden = true
        }
    }
}
