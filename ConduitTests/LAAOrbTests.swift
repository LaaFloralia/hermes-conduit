#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// The particle orb (owner, 2026-11-14) and Send's rim reflection.
@MainActor
final class LAAOrbTests: XCTestCase {
    func testKitOrbKeepsTheHostSlotAtRowAndHeroSizes() {
        for diameter: CGFloat in [LAATranscriptMetrics.thoughtOrb, 120] {
            let renderer = ImageRenderer(content: LAAOrbView(state: .speaking, level: 1, diameter: diameter))
            renderer.render { size, _ in
                XCTAssertEqual(size, CGSize(width: diameter, height: diameter))
            }
        }
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

    /// Compare the kit orb in a transcript row and at voice size in both appearances.
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

        }
    }
}
#endif
