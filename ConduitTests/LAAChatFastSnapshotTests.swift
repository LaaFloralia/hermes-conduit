#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// 440 × 956 pt light and dark captures of the chat composer's three
/// capsules (owner, 2026-11-14): model · effort · Fast in every speed, the
/// locked state, and Monet · Dots' fixed Astra · Max · Ultrafast.
/// Attachments are exported from the result bundle.
@MainActor
final class LAAChatFastSnapshotTests: XCTestCase {
    func testComposerCapsulesLightAndDark() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            try capture(gallery, style: style, name: "chat-fast-\(style == .dark ? "dark" : "light")")
        }
    }

    private func fast(_ speed: ModelSpeed, ultrafast: Bool = false, writing: Bool = false) -> LAAChatFastControl.Display {
        LAAChatFastControl.display(speed: speed, capability: .init(fast: true, ultrafast: ultrafast), sessionID: "s",
                                   connected: true, writable: true, writing: writing)!
    }

    private func composer(_ model: String, _ provider: String, _ effort: String, _ display: LAAChatFastControl.Display,
                          name: String? = nil, changing: Bool = false, running: Bool = false) -> some View {
        // The composer's controls row as ComposerBar lays it out: + at the
        // start, Send (Stop and Send while a reply runs) at the end, and the
        // capsules on their own line above them when their names need it.
        LAAComposerControlsRow {
            LAAGlassActionButton(systemImage: "photo", label: "写真", role: .neutral) {}
            LAAWrapRow {
                LAAModelEffortPickers(model: model, provider: provider, effort: effort, name: name, identifier: "snapshot") {
                    EmptyView()
                } effortMenu: {
                    EmptyView()
                }
                LAAChatFastCapsule(display: display, changing: changing, identifier: "snapshot.fast") { _ in }
            }
            HStack(spacing: LAASpacing.x2) {
                if running { LAAGlassActionButton(systemImage: "stop.fill", label: "停止", role: .stop) {} }
                LAAGlassActionButton(systemImage: "arrow.up", label: "送信") {}
            }
        }
    }

    private func row(_ title: String, _ content: some View) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: title).font(.caption).foregroundStyle(LAAColor.secondaryText)
            content
        }
    }

    private var gallery: some View {
        let dots = LAAChatFixedRuntime.dots
        return ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x5) {
                row("Opus 5.5 · High · 通常", composer("claude-opus-5-5", "claude", "high", fast(.normal)))
                row("Opus 5.5 · High · Fast・応答中", composer("claude-opus-5-5", "claude", "high", fast(.fast), running: true))
                row("GPT 6 Astra · XHigh · 通常（Ultrafastあり）", composer("gpt-6-astra", "openai-codex", "xhigh", fast(.normal, ultrafast: true)))
                row("GPT 6 Astra · XHigh · Ultrafast", composer("gpt-6-astra", "openai-codex", "xhigh", fast(.ultrafast, ultrafast: true)))
                row("Mythos 5.2 · Max · Fast", composer("claude-mythos-5-2", "claude", "max", fast(.fast)))
                row("Mythos 5.2 · Ultra Code · Fast・応答中", composer("claude-mythos-5-2", "claude", "ultracode", fast(.fast), running: true))
                row("DeepSeek · High · 変更中", composer("deepseek-v4.1-flash", "laa-dsh", "high", fast(.normal, writing: true), changing: true))
                row("Monet（Dots）固定", composer(dots.model, dots.provider, dots.effort, dots.fast, name: dots.name))
            }
            .padding(LAASpacing.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LAAColor.background.ignoresSafeArea())
    }

    private func capture<V: View>(_ view: V, style: UIUserInterfaceStyle, settle: TimeInterval = 0.8, name: String) throws {
        let screen = view
            .environment(\.locale, Locale(identifier: "ja_JP"))
            .preferredColorScheme(style == .dark ? .dark : .light)
        let host = UIHostingController(rootView: screen)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.verticalSizeClass = .regular
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        XCTAssertEqual(image.cgImage?.width, 440)
        XCTAssertEqual(image.cgImage?.height, 956)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
