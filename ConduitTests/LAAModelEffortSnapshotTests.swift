#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// 440 × 956 pt light and dark captures of the model and effort pickers
/// (owner, 2026-11-12): every state of the two capsules, the new-session
/// sheet and the task form. Attachments are exported from the result bundle.
@MainActor
final class LAAModelEffortSnapshotTests: XCTestCase {
    private let options = LAAWorkSessionOptions(profiles: [
        .init(id: "opus-high", label: "Claude Opus 5.5", provider: "claude", model: "claude-opus-5-5", effort: "high", fast: true),
        .init(id: "opus-xhigh", label: "Claude Opus 5.5", provider: "claude", model: "claude-opus-5-5", effort: "xhigh", fast: true),
        .init(id: "mythos-high", label: "Claude Mythos 5.2", provider: "claude", model: "claude-mythos-5-2", effort: "high", fast: false),
        .init(id: "astra-max", label: "GPT-6 Astra", provider: "codex", model: "gpt-6-astra", effort: "max", fast: true),
        .init(id: "dsh-high", label: "DeepSeek V4.1 Flash", provider: "dsh", model: "deepseek-v4.1-flash", effort: "high", fast: false),
    ], defaultProfile: "opus-high", defaultMode: "bypass")

    func testPickerStatesLightAndDark() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            try capture(gallery, style: style, name: "pickers-states-\(style == .dark ? "dark" : "light")", settle: 1.6)
        }
    }

    func testLauncherAndTaskFormLightAndDark() throws {
        UserDefaults.standard.removeObject(forKey: LAAWorkModelPreferences.lastKey)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let suffix = style == .dark ? "dark" : "light"
            try capture(LAAWorkSessionLauncher(projects: [], options: options,
                                               drafts: LAAWorkDrafts.makeStore(fileURL: tempFile())) { _ in },
                        style: style, name: "pickers-launcher-\(suffix)")
            try capture(LAALinearTaskEditor(id: "new", task: nil, busy: false, failure: .constant(nil), options: options) { _ in },
                        style: style, name: "pickers-task-\(suffix)")
        }
    }

    private func row(_ title: String, _ pickers: some View) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: title).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            pickers
        }
    }

    private func pickers(_ model: String?, _ provider: String?, _ effort: String?, current: Bool = true,
                         attention: Bool = false, changing: Bool = false) -> some View {
        LAAModelEffortPickers(model: model, provider: provider, effort: effort, current: current,
                              attention: attention, changingEffort: changing, identifier: "snapshot") {
            EmptyView()
        } effortMenu: { EmptyView() }
    }

    private var gallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x5) {
                row("Opus 5.5 · High", pickers("claude-opus-5-5", "claude", "high"))
                row("Mythos 5.2 · XHigh", pickers("claude-mythos-5-2", "claude", "xhigh"))
                row("GPT 6.1 Sol · Max", pickers("gpt-6.1-sol", "codex", "max"))
                row("DeepSeek · Low", pickers(#"["opencode-go","deepseek-v4.1-flash"]"#, "dsh", "low"))
                row("不明 · 不明", pickers(nil, nil, nil))
                row("最終確認", pickers("claude-fable-5-2", "claude", "xhigh", current: false))
                row("依頼と実行の不一致・変更中", pickers("claude-opus-4-8", "claude", "high", attention: true, changing: true))
                row("狭い行（名前は丸ごと省く）", HStack(spacing: LAASpacing.x2) {
                    LAAGlassActionButton(systemImage: "photo", label: "写真", role: .neutral) {}
                    pickers("claude-mythos-5-2", "claude", "xhigh")
                    Spacer(minLength: 0)
                }.frame(width: 170, alignment: .leading))
            }
            .padding(LAASpacing.horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LAAColor.background.ignoresSafeArea())
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("laa-picker-snapshot-\(UUID().uuidString).json")
    }

    private func capture<V: View>(_ view: V, style: UIUserInterfaceStyle, name: String, settle: TimeInterval = 0.8) throws {
        let bridge = LAABridgeSession(statusForTesting: .paired)
        let screen = view.environmentObject(bridge)
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
