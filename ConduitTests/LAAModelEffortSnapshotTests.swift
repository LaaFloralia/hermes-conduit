#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// 440 × 956 pt light and dark captures of the model and effort pickers
/// (owner, 2026-11-12): every state of the two capsules, each finish (no
/// line, one, two), the new-session sheet and the task form. Attachments are
/// exported from the result bundle.
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
            try capture(gallery, style: style, settle: 1.6, name: "pickers-states-\(style == .dark ? "dark" : "light")")
        }
    }

    /// The one movement, held at moments 0 to 420 ms (owner, 2026-11-14): the
    /// light runs round the rim from the leading end and leaves the tan lines.
    /// Two blocks, so every capsule fits the 440 pt width.
    func testCeremonyMomentsLightAndDark() throws {
        let moments: [Double] = [0, 0.07, 0.14, 0.21, 0.28, 0.35, 0.42]
        func block(@ViewBuilder _ capsules: @escaping (Double) -> some View) -> some View {
            VStack(alignment: .leading, spacing: LAASpacing.x3) {
                ForEach(moments, id: \.self) { t in
                    HStack(spacing: LAASpacing.x2) {
                        Text(verbatim: "\(Int((t * 1000).rounded()))").font(.caption.monospacedDigit())
                            .foregroundStyle(LAAColor.secondaryText).frame(width: 28, alignment: .trailing)
                        capsules(t)
                    }
                }
            }
        }
        let strip = VStack(alignment: .leading, spacing: LAASpacing.x6) {
            block { t in
                LAAModelCapsule(model: "claude-mythos-5-2", provider: "claude").face(elapsed: t).fixedSize()
                LAAEffortCapsule(effort: "max").capsule(elapsed: t)
            }
            block { t in
                LAAEffortCapsule(effort: "xhigh").capsule(elapsed: t)
                LAAEffortCapsule(effort: "high").capsule(elapsed: t)
                LAAEffortCapsule(effort: "low").capsule(elapsed: t)
            }
        }
        .padding(LAASpacing.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LAAColor.background.ignoresSafeArea())
        for style in [UIUserInterfaceStyle.light, .dark] {
            try capture(strip, style: style, name: "pickers-ceremony-\(style == .dark ? "dark" : "light")")
        }
    }

    /// The same movement frame by frame at 30 a second, on the real glass, for
    /// a short recording put together from the attachments: each model
    /// standing and each effort, then the lines at rest.
    func testCeremonyFramesLightAndDark() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for frame in 0...18 {
                let t = Double(frame) / 30
                let board = VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    HStack(spacing: LAASpacing.x2) {
                        LAAModelCapsule(model: "claude-mythos-5-2", provider: "claude").face(elapsed: t).fixedSize()
                        LAAEffortCapsule(effort: "max").capsule(elapsed: t)
                    }
                    HStack(spacing: LAASpacing.x2) {
                        LAAModelCapsule(model: "claude-fable-5-2", provider: "claude").face(elapsed: t).fixedSize()
                        LAAEffortCapsule(effort: "xhigh").capsule(elapsed: t)
                    }
                    HStack(spacing: LAASpacing.x2) {
                        LAAModelCapsule(model: "gpt-6.1-sol", provider: "codex").face(elapsed: t).fixedSize()
                        LAAEffortCapsule(effort: "high").capsule(elapsed: t)
                    }
                    HStack(spacing: LAASpacing.x2) {
                        LAAModelCapsule(model: #"["opencode-go","deepseek-v4.1-flash"]"#, provider: "dsh").face(elapsed: t).fixedSize()
                        LAAEffortCapsule(effort: "medium").capsule(elapsed: t)
                        LAAEffortCapsule(effort: "low").capsule(elapsed: t)
                    }
                }
                .padding(LAASpacing.horizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(LAAColor.background.ignoresSafeArea())
                try capture(board, style: style, settle: 0.25,
                            name: String(format: "ceremony-frame-%@-%02d", style == .dark ? "dark" : "light", frame))
            }
        }
    }

    /// Every effort on each provider's model (owner, 2026-11-14: Mythos, Opus,
    /// GPT and DeepSeek at each effort), then the other faces at High.
    func testEveryModelAndEffortLightAndDark() throws {
        let models: [(String, String)] = [("claude-mythos-5-2", "claude"), ("claude-opus-5-5", "claude"),
                                          ("gpt-6.1-sol", "codex"), (#"["opencode-go","deepseek-v4.1-flash"]"#, "dsh")]
        let efforts = ["low", "medium", "high", "xhigh", "max"]
        let others: [(String, String)] = [("claude-fable-5-2", "claude"), ("gpt-6-astra", "codex"), ("claude-sonnet-5-5", "claude"),
                                          ("gpt-6.1-terra", "codex"), ("claude-haiku-5-5", "claude")]
        func page(_ rows: [(String, String, String)]) -> some View {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in pickers(row.0, row.1, row.2) }
            }
            .padding(LAASpacing.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LAAColor.background.ignoresSafeArea())
        }
        let grid = models.flatMap { model in efforts.map { (model.0, model.1, $0) } }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let suffix = style == .dark ? "dark" : "light"
            try capture(page(grid), style: style, settle: 1.6, name: "pickers-grid-\(suffix)")
            try capture(page(others.map { ($0.0, $0.1, "high") }), style: style, settle: 1.6, name: "pickers-others-\(suffix)")
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
                // Standing is the number of tan lines on the rim (owner, 2026-11-14): none, one, two.
                row("Mythos 5.2 · Max（2本・2本）", pickers("claude-mythos-5-2", "claude", "max"))
                row("Fable 5.2 · XHigh（1本・1本）", pickers("claude-fable-5-2", "claude", "xhigh"))
                row("GPT 6 Astra · High（1本・なし）", pickers("gpt-6-astra", "codex", "high"))
                row("Opus 5.5 · Medium", pickers("claude-opus-5-5", "claude", "medium"))
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

    private func capture<V: View>(_ view: V, style: UIUserInterfaceStyle, settle: TimeInterval = 0.8, name: String) throws {
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
