#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// The particle orb (owner, 2026-11-14) and Send's rim reflection.
@MainActor
final class LAAOrbTests: XCTestCase {
    /// One frame of the orb at `size` points, 2x, as RGBA bytes.
    private func frame(size: CGFloat = 24, wave: Double = 1, beat: Double = 0.4, thinking: Double = 1,
                       level: Double = 0, ground: LAAParticleOrb.Ground = .dark) throws -> (bytes: [UInt8], side: Int) {
        let side = size * 1.3
        let renderer = ImageRenderer(content: Canvas { context, canvas in
            LAAParticleOrb.draw(&context, canvas: canvas, size: size, displayScale: 2, beat: beat, wave: wave,
                                spin: 0, level: level, thinking: thinking, solid: false, ground: ground)
        }.frame(width: side, height: side))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "the orb renders")
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width)
    }

    private func light(_ frame: (bytes: [UInt8], side: Int), x: Int, y: Int) -> Int {
        let i = (y * frame.side + x) * 4
        return Int(frame.bytes[i]) + Int(frame.bytes[i + 1]) + Int(frame.bytes[i + 2])
    }

    private func total(_ frame: (bytes: [UInt8], side: Int)) -> Int {
        stride(from: 0, to: frame.bytes.count, by: 4).reduce(0) { $0 + Int(frame.bytes[$1]) + Int(frame.bytes[$1 + 1]) + Int(frame.bytes[$1 + 2]) }
    }

    func testTheOrbIsBrightAtItsHeartAndLeavesItsCornersClear() throws {
        let orb = try frame()
        let mid = orb.side / 2
        XCTAssertGreaterThan(light(orb, x: mid, y: mid), 600, "the heart is close to white")
        XCTAssertEqual(orb.bytes[3], 0, "the corner of the canvas stays transparent")
        XCTAssertEqual(orb.bytes[(orb.side * orb.side - 1) * 4 + 3], 0, "the far corner stays transparent")
    }

    func testTheSameMomentDrawsTheSameOrbAndTheLoopCloses() throws {
        let first = try frame(wave: 1.3)
        XCTAssertEqual(first.bytes, try frame(wave: 1.3).bytes, "a moment is a pure function of its phases")
        let start = try frame(wave: 0), end = try frame(wave: 2 * .pi)
        let differing = zip(start.bytes, end.bytes).filter { abs(Int($0) - Int($1)) > 2 }.count
        XCTAssertLessThan(Double(differing) / Double(start.bytes.count), 0.01, "one turn of the wave returns to the first frame")
    }

    func testThinkingLightsMoreOfTheOrbThanWaiting() throws {
        XCTAssertGreaterThan(total(try frame(thinking: 1)), total(try frame(thinking: 0)), "more particles are lit while thinking")
    }

    func testAVoiceBrightensTheOrb() throws {
        XCTAssertGreaterThan(total(try frame(size: 120, level: 1)), total(try frame(size: 120, level: 0)), "the orb follows the voice")
    }

    func testTheGroundFollowsTheAppearanceAndTheSize() {
        XCTAssertEqual(LAAOrbView.ground(dark: true, diameter: 24), .dark)
        XCTAssertEqual(LAAOrbView.ground(dark: true, diameter: 120), .darkRim, "a large orb gets its outline")
        XCTAssertEqual(LAAOrbView.ground(dark: false, diameter: 24), .paperBead, "on paper the particles stand in ink, with no bead")
        XCTAssertEqual(LAAOrbView.ground(dark: false, diameter: 120), .paperBead)
    }

    func testTheRimReflectionIsOneClosedLoopOfLight() {
        let stops = LAAGlassRimReflection.stops
        XCTAssertEqual(stops.first?.at, 0)
        XCTAssertEqual(stops.last?.at, 1)
        XCTAssertEqual(stops.first?.lit, stops.last?.lit, "the turn closes without a seam")
        XCTAssertEqual(stops.map(\.at), stops.map(\.at).sorted(), "the stops run round the rim in order")
        let lit = zip(stops, stops.dropFirst()).filter { $0.lit && $1.lit }.reduce(0.0) { $0 + $1.1.at - $1.0.at }
        XCTAssertLessThan(lit, 0.15, "the light is a glint, not a lit ring")
    }

    /// 440 × 956 pt light and dark captures of the orb where the app shows it
    /// (owner, 2026-11-14): the typing row in each state, Work's progress
    /// line, the mark under a streaming reply, the voice size, and Send's rim.
    /// Then the same page 36 times a twelfth of a second apart, for a short
    /// recording put together from the attachments.
    func testShotsOfTheOrbInItsRows() throws {
        func label(_ text: String) -> some View {
            Text(verbatim: text).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }
        let page = VStack(alignment: .leading, spacing: LAASpacing.x4) {
            label("Chat・考えています")
            LAATypingDots(startedAt: Date().addingTimeInterval(-12), state: .thinking, phrase: "考えています")
            label("Chat・道具を使っています")
            LAATypingDots(state: .tool, phrase: "ファイルを読んでいます")
            label("Chat・別の端末へ返信中（静かな球）")
            LAATypingDots(state: .idle, phrase: "別の端末へ返信中")
            label("Work・進行行")
            LAAWorkProgressLine(compacting: false)
            label("返信の下の印（18 pt）と LAA Voice の大きさ（120 pt）")
            HStack(alignment: .center, spacing: LAASpacing.x6) {
                LAAOrbView(state: .thinking, diameter: 18)
                LAAOrbView(state: .speaking, level: 0.6, diameter: 120)
            }
            .padding(.vertical, LAASpacing.x4)
            label("送信ボタンの縁の反射")
            HStack(spacing: LAASpacing.x3) {
                LAAGlassActionButton(systemImage: "arrow.up", label: "送信") {}
                LAAGlassActionButton(systemImage: "stop.fill", label: "中断", role: .stop) {}
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LAAColor.background.ignoresSafeArea())
        // A hosting controller outside the app's own scene reads `.background`, which would hold the orb still.
        .environment(\.scenePhase, .active)

        for style in [UIUserInterfaceStyle.light, .dark] {
            let suffix = style == .dark ? "dark" : "light"
            let host = UIHostingController(rootView: page.preferredColorScheme(style == .dark ? .dark : .light))
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: try XCTUnwrap(previous?.windowScene ?? scenes.first))
            window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
            window.traitOverrides.horizontalSizeClass = .compact
            window.traitOverrides.verticalSizeClass = .regular
            window.traitOverrides.userInterfaceStyle = style
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
            func shot(_ name: String) {
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            shot("orb-rows-\(suffix)")
            let start = Date()
            var times: [String] = []
            for index in 0..<36 {
                RunLoop.current.run(until: start.addingTimeInterval(Double(index) / 12))
                times.append(String(format: "%.3f", Date().timeIntervalSince(start)))
                shot(String(format: "orb-frame-%@-%02d", suffix, index))
            }
            let stamps = XCTAttachment(string: times.joined(separator: "\n"))
            stamps.name = "orb-frame-times-\(suffix)"
            stamps.lifetime = .keepAlways
            add(stamps)
        }
    }
}
#endif
