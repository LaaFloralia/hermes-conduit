#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// The owner's 2026-11-11 round: the model menu, the stop control, the
/// resizable follow-up field, model faces, message actions and Usage's refresh.
@MainActor
final class LAAChatPolishTests: XCTestCase {
    private let options = """
    {"profiles":[
     {"id":"opus-high","label":"Claude Opus 5.5","provider":"claude","model":"claude-opus-5-5","effort":"high","fast":true},
     {"id":"opus-xhigh","label":"Claude Opus 5.5","provider":"claude","model":"claude-opus-5-5","effort":"xhigh","fast":true},
     {"id":"sonnet-high","label":"Claude Sonnet 5.5","provider":"claude","model":"claude-sonnet-5-5","effort":"high","fast":false},
     {"id":"sol-high","label":"GPT-6.1 Sol","provider":"codex","model":"gpt-6.1-sol","effort":"high","fast":true}
    ],"defaultProfile":"opus-high","defaultMode":"bypass"}
    """

    private func session(provider: String = "claude", model: String = "claude-opus-5-5", effort: String = "high",
                         phase: String = "running", capabilities: String = #"{"effort":true,"fast":true,"model":true}"#)
        throws -> LAAWorkSession {
        let json = """
        {"id":"ses_5555555555555555","name":"実行中の会話","requestId":"r","workspaceId":"w","profile":"opus-high",
         "requested":{"provider":"\(provider)","model":"\(model)","effort":"\(effort)"},
         "observed":{"provider":"\(provider)","model":"\(model)","effort":"\(effort)"},
         "runtimeVerified":true,"observedFast":false,"capabilities":\(capabilities),"phase":"\(phase)",
         "createdAt":"2026-11-06T00:00:00Z","updatedAt":"2026-11-06T00:00:00Z",
         "events":{"lastSeq":1,"oldestSeq":1,"cursor":"c"},"observation":{"available":true,"code":null}}
        """
        return try JSONDecoder().decode(LAAWorkSession.self, from: Data(json.utf8))
    }

    private var decodedOptions: LAAWorkSessionOptions {
        get throws { try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data(options.utf8)) }
    }

    // MARK: - 1. The running session's model menu

    func testModelChoicesStayWithinTheProviderAndTheCapabilityDecodes() throws {
        let running = try session()
        XCTAssertEqual(running.capabilities?.model, true)
        let choices = LAAWorkSessionStyle.modelChoices(running, options: try decodedOptions)
        XCTAssertEqual(choices.map(\.model), ["claude-opus-5-5", "claude-sonnet-5-5"],
                       "one row per model, no GPT model for a Claude session")
        XCTAssertEqual(choices.map(\.label), ["Opus 5.5", "Sonnet 5.5"])
        let gpt = try session(provider: "codex", model: "gpt-6.1-sol")
        XCTAssertEqual(LAAWorkSessionStyle.modelChoices(gpt, options: try decodedOptions).map(\.model), ["gpt-6.1-sol"])
        // An older Bridge says nothing about model changes.
        let old = try session(capabilities: #"{"effort":true}"#)
        XCTAssertNil(old.capabilities?.model)
    }

    func testListRowNamesTheModelTheOwnerSwitchedTo() throws {
        let switched = try session(model: "claude-sonnet-5-5")
        XCTAssertEqual(LAAWorkSessionStyle.model(switched, options: try decodedOptions), "Sonnet 5.5 High")
        let same = try session()
        XCTAssertEqual(LAAWorkSessionStyle.model(same, options: try decodedOptions), "Opus 5.5 High")
    }

    // MARK: - 4. Model faces

    func testEachModelFamilyGetsItsOwnFace() {
        XCTAssertEqual(LAAModelFace.face(model: "claude-opus-5-5", provider: "claude"), .claude)
        XCTAssertEqual(LAAModelFace.face(model: "claude-sonnet-5-5", provider: "claude"), .claude)
        XCTAssertEqual(LAAModelFace.face(model: "claude-haiku-5-5", provider: "claude"), .claude)
        XCTAssertEqual(LAAModelFace.face(model: "claude-mythos-5-2", provider: nil), .claude)
        XCTAssertEqual(LAAModelFace.face(model: "claude-fable-5-2", provider: nil), .claude)
        XCTAssertEqual(LAAModelFace.face(model: "gpt-6.1-sol", provider: "codex"), .gpt(.sol))
        XCTAssertEqual(LAAModelFace.face(model: "gpt-6.1-terra", provider: "codex"), .gpt(.terra))
        XCTAssertEqual(LAAModelFace.face(model: "gpt-6-luna", provider: "codex"), .gpt(.luna))
        XCTAssertEqual(LAAModelFace.face(model: "gpt-6-astra", provider: "codex"), .gpt(.astra))
        XCTAssertEqual(LAAModelFace.face(model: "gpt-5", provider: nil), .gpt(.other))
        XCTAssertEqual(LAAModelFace.face(model: #"["opencode-go","deepseek-v4.1-flash"]"#, provider: "dsh"), .deepSeek)
        XCTAssertEqual(LAAModelFace.face(model: "gemini-3-pro", provider: nil), .gemini)
        XCTAssertEqual(LAAModelFace.face(model: "grok-5", provider: nil), .grok)
        XCTAssertEqual(LAAModelFace.face(model: "laa-router", provider: "other"), .unknown)
        XCTAssertEqual(LAAModelFace.face(model: nil, provider: nil), .unknown)
    }

    /// The model menu keeps its readable label; model rank belongs to the
    /// selected glass control and adds no ring ornaments to menu rows.
    func testMenuRowsDoNotAddModelRankOrnaments() throws {
        for scheme in [ColorScheme.light, .dark] {
            func rendered(_ model: String?) throws -> Data {
                let row = LAAModelMenu.Name(label: "Same label", model: model)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: row)
                renderer.scale = 2
                return try XCTUnwrap(UIImage(cgImage: XCTUnwrap(renderer.cgImage)).pngData())
            }
            let plain = try rendered(nil)
            for model in ["claude-opus-5-5", "claude-mythos-5-2", "claude-fable-5-2", "gpt-6-astra"] {
                XCTAssertEqual(try rendered(model), plain)
            }
        }
    }

    // MARK: - 5. Quote and good

    func testQuoteIsAMarkdownBlockAddedAfterTheDraft() {
        XCTAssertEqual(LAAWorkQuoteRequest.markdown("一行目\n\n二行目"), "> 一行目\n>\n> 二行目\n\n")
        XCTAssertEqual(LAAWorkQuoteRequest.markdown("   "), "")
        let long = LAAWorkQuoteRequest.markdown(String(repeating: "あ", count: 500), limit: 10)
        XCTAssertEqual(long, "> " + String(repeating: "あ", count: 10) + "…\n\n")
        XCTAssertEqual(LAAWorkQuoteRequest.inserting("> q\n\n", into: ""), "> q\n\n")
        XCTAssertEqual(LAAWorkQuoteRequest.inserting("> q\n\n", into: "書きかけ"), "書きかけ\n\n> q\n\n",
                       "a draft in progress is kept, the quote goes after it")
        XCTAssertEqual(LAAWorkQuoteRequest.inserting("> q\n\n", into: "a\n\n"), "a\n\n> q\n\n")
    }

    func testGoodMarksToggleAndKeepTheNewestWithinCapacity() {
        let key = LAAWorkLikes.key(session: "s", message: "m")
        let on = LAAWorkLikes.toggled("", key: key)
        XCTAssertEqual(LAAWorkLikes.decode(on), ["s/m"])
        XCTAssertEqual(LAAWorkLikes.decode(LAAWorkLikes.toggled(on, key: key)), [])
        var raw = ""
        for index in 0..<(LAAWorkLikes.capacity + 3) { raw = LAAWorkLikes.toggled(raw, key: "s/\(index)") }
        let kept = LAAWorkLikes.decode(raw)
        XCTAssertEqual(kept.count, LAAWorkLikes.capacity)
        XCTAssertEqual(kept.first, "s/3")
        XCTAssertEqual(kept.last, "s/\(LAAWorkLikes.capacity + 2)")
    }

    // MARK: - Pictures (440 × 956, light and dark)

    func testShotsOfTheFollowUpRowTranscriptAndFaces() throws {
        let running = try session()
        let opts = try decodedOptions
        let store = ComposerDraftStore(capacity: 10, fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("laa-polish-\(UUID().uuidString).json"))
        let likes = UserDefaults.standard.string(forKey: LAAWorkLikes.storageKey)
        UserDefaults.standard.set(LAAWorkLikes.key(session: running.id, message: "a2"), forKey: LAAWorkLikes.storageKey)
        defer { UserDefaults.standard.set(likes, forKey: LAAWorkLikes.storageKey) }
        let messages: [LAAWorkConversationMessage] = [
            .init(id: "u1", role: "user", text: "見積りの比較表を作って、安い順に並べてください。", timestamp: "2026-11-11T01:00:00Z"),
            .init(id: "a1", role: "assistant", text: "3社の見積りを比較しました。最安はB社で、納期はA社が最短です。", timestamp: "2026-11-11T01:01:00Z"),
            .init(id: "u2", role: "user", text: "B社の条件をもう少し詳しく。", timestamp: "2026-11-11T01:02:00Z"),
            .init(id: "a2", role: "assistant", text: "B社は前払い50%、納期は3週間です。", timestamp: "2026-11-11T01:03:00Z"),
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            let suffix = style == .dark ? "dark" : "light"
            let page = VStack(alignment: .leading, spacing: LAASpacing.x4) {
                LAAWorkSessionHeaderPill(session: running)
                ForEach(Array(messages.enumerated()), id: \.element.id) { _, message in
                    LAAWorkMessageRow(message: message, sessionID: running.id, agentName: "Opus 5.5 · High",
                                      continues: false, responseSize: ChatTypography.defaultSize.rawValue,
                                      model: running.observed, onQuote: { _ in })
                }
                Spacer(minLength: 0)
                LAAWorkMessageForm(
                    sessionID: running.id, mode: .followUp, drafts: store, canStart: true,
                    settingsRow: AnyView(LAAWorkSessionControls(session: running, options: opts,
                                                                changing: .constant(false), changingFast: .constant(false),
                                                                notice: .constant(nil)) {}),
                    interrupt: AnyView(stopReplica)
                ) { _ in }
            }
            .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, 60)
            try capture(page, style: style, name: "work-session-polish-\(suffix)")

            let faces = VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.faceSamples, id: \.0) { sample in
                    HStack(spacing: 12) {
                        LAAModelMark(model: sample.1, provider: sample.2, size: 40)
                        LAAModelMark(model: sample.1, provider: sample.2, size: 22)
                        Text(verbatim: sample.0).font(.body).foregroundStyle(LAAColor.text)
                    }
                }
            }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            try capture(faces, style: style, name: "model-faces-\(suffix)")
        }
    }

    static let faceSamples: [(String, String?, String?)] = [
        ("Opus 5.5", "claude-opus-5-5", "claude"), ("Sonnet 5.5", "claude-sonnet-5-5", "claude"),
        ("Haiku 5.5", "claude-haiku-5-5", "claude"), ("Mythos 5.2", "claude-mythos-5-2", "claude"),
        ("Fable 5.2", "claude-fable-5-2", "claude"), ("GPT-6.1 Sol", "gpt-6.1-sol", "codex"),
        ("GPT-6.1 Terra", "gpt-6.1-terra", "codex"), ("GPT-6 Luna", "gpt-6-luna", "codex"),
        ("GPT-6 Astra", "gpt-6-astra", "codex"), ("DeepSeek V4.1 Flash", #"["opencode-go","deepseek-v4.1-flash"]"#, "dsh"),
        ("Gemini", "gemini-3-pro", nil), ("Grok", "grok-5", nil), ("その他", "laa-router", "other"),
    ]

    /// The detail's stop control is private to it; this is the same drawing.
    private var stopReplica: some View {
        Image(systemName: "stop.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(LAAColor.end)
            .frame(width: 36, height: 36)
            .conduitGlassControl(cornerRadius: 18, tint: LAAColor.end.opacity(0.10), interactive: true)
    }

    private func capture<V: View>(_ view: V, style: UIUserInterfaceStyle, name: String) throws {
        let bridge = LAABridgeSession(statusForTesting: .paired)
        let screen = ZStack { LAAColor.background.ignoresSafeArea(); view }
            .environmentObject(bridge)
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
