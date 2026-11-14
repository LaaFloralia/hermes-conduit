#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// 440 × 956 pt light and dark captures of the model and effort pickers
/// (owner, 2026-11-14): every state of the two capsules, the light each
/// standing holds, the new-session sheet and the task form. Attachments are
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

    /// The one movement, held at moments 0 to 420 ms (owner, 2026-11-14): a
    /// pass of light crosses the glass from the leading end and the standing
    /// light settles behind it.
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
    /// standing and each effort, then their finishes at rest.
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
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in self.pickers(row.0, row.1, row.2) }
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

    // MARK: Before and after a choice, for comparing one version with another

    /// The four models the owner compares, and every effort including Ultra Code.
    private static let compareModels: [(model: String, provider: String, slug: String)] = [
        ("claude-mythos-5-2", "claude", "mythos"), ("claude-opus-5-5", "claude", "opus"),
        ("gpt-6.1-sol", "codex", "gpt"), (#"["opencode-go","deepseek-v4.1-flash"]"#, "dsh", "dsh"),
    ]
    private static let compareEfforts = ["low", "medium", "high", "xhigh", "max", "ultracode"]
    /// What the capsules showed before the choice: the house default, or one
    /// step down when the default itself is the choice.
    private static func previous(_ model: String, _ effort: String) -> (String, String, String) {
        model == "claude-opus-5-5" && effort == "high"
            ? ("claude-opus-5-5", "claude", "medium") : ("claude-opus-5-5", "claude", "high")
    }

    /// One pair of capsules for a target, `phase` "before" (the previous value
    /// at rest), "moment" (`fraction` of each moving capsule's own movement)
    /// or "after" (at rest). Only a capsule whose value changed moves.
    @ViewBuilder
    private func comparePair(_ model: String, _ provider: String, _ effort: String,
                             phase: String, fraction: Double) -> some View {
        let before = Self.previous(model, effort)
        let shown = phase == "before" ? before : (model, provider, effort)
        let modelMoves = phase == "moment" && before.0 != model
        let effortMoves = phase == "moment" && before.2 != effort
        HStack(spacing: LAASpacing.x2) {
            LAAModelCapsule(model: shown.0, provider: shown.1)
                .face(elapsed: modelMoves ? fraction * LAACeremony.duration(rank: LAAModelRank.of(model)) : nil)
                .fixedSize()
            LAAEffortCapsule(effort: shown.2)
                .capsule(elapsed: effortMoves ? fraction * LAACeremony.duration(effort: effort) : nil)
        }
        .frame(height: 48, alignment: .leading)
    }

    /// A 440 pt page per model, scheme and phase: six rows of 48 pt from
    /// y = 24, one per effort, so the boards can be cut and set side by side.
    func testCompareBoardsLightAndDark() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let suffix = style == .dark ? "dark" : "light"
            for entry in Self.compareModels {
                for phase in ["before", "moment", "after"] {
                    let page = VStack(alignment: .leading, spacing: 0) {
                        ForEach(Self.compareEfforts, id: \.self) { effort in
                            self.comparePair(entry.model, entry.provider, effort, phase: phase, fraction: 0.45)
                        }
                    }
                    .padding(.top, 24).padding(.horizontal, LAASpacing.horizontal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(LAAColor.background.ignoresSafeArea())
                    try capture(page, style: style, settle: 0.6, scale: 2, name: "compare-\(suffix)-\(entry.slug)-\(phase)")
                }
            }
        }
    }

    /// The movement at 120 frames a second from the moment the value arrives
    /// to 500 ms, after the previous values at rest: frame "pre", then 000 to
    /// 060. Five choices: Mythos Max, Opus XHigh, GPT Medium, DeepSeek Low,
    /// Mythos Ultra Code.
    func testCompareMotionFramesLightAndDark() throws {
        let rows: [(String, String, String)] = [
            ("claude-mythos-5-2", "claude", "max"), ("claude-opus-5-5", "claude", "xhigh"),
            ("gpt-6.1-sol", "codex", "medium"), (#"["opencode-go","deepseek-v4.1-flash"]"#, "dsh", "low"),
            ("claude-mythos-5-2", "claude", "ultracode"),
        ]
        func board(phase: String, seconds: Double) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    self.motionPair(row.0, row.1, row.2, phase: phase, seconds: seconds)
                }
            }
            .padding(.top, 24).padding(.horizontal, LAASpacing.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LAAColor.background.ignoresSafeArea())
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let suffix = style == .dark ? "dark" : "light"
            try capture(board(phase: "before", seconds: 0), style: style, settle: 0.4, scale: 2, name: "motion-\(suffix)-pre")
            for frame in 0...60 {
                try capture(board(phase: "moment", seconds: Double(frame) / 120), style: style, settle: 0.15, scale: 2,
                            name: String(format: "motion-%@-%03d", suffix, frame))
            }
        }
    }

    @ViewBuilder
    private func motionPair(_ model: String, _ provider: String, _ effort: String,
                            phase: String, seconds: Double) -> some View {
        let before = Self.previous(model, effort)
        let shown = phase == "before" ? before : (model, provider, effort)
        let moving = phase == "moment"
        HStack(spacing: LAASpacing.x2) {
            LAAModelCapsule(model: shown.0, provider: shown.1)
                .face(elapsed: moving && before.0 != model ? seconds : nil)
                .fixedSize()
            LAAEffortCapsule(effort: shown.2)
                .capsule(elapsed: moving && before.2 != effort ? seconds : nil)
        }
        .frame(height: 48, alignment: .leading)
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
                // Standing is light in the glass; menu rows have no ring ornaments.
                row("Mythos 5.2 · Max", pickers("claude-mythos-5-2", "claude", "max"))
                row("Fable 5.2 · XHigh", pickers("claude-fable-5-2", "claude", "xhigh"))
                row("GPT 6 Astra · High", pickers("gpt-6-astra", "codex", "high"))
                row("Mythos 5.2 · Ultra Code", pickers("claude-mythos-5-2", "claude", "ultracode"))
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

    private func capture<V: View>(_ view: V, style: UIUserInterfaceStyle, settle: TimeInterval = 0.8, scale: CGFloat = 1,
                                  name: String) throws {
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
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        XCTAssertEqual(image.cgImage?.width, Int(440 * scale))
        XCTAssertEqual(image.cgImage?.height, Int(956 * scale))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
