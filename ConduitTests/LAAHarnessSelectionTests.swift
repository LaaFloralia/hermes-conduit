#if LAA_BUILD
import XCTest
@testable import Conduit

/// The harness selector (owner, 2026-11-26): Work's harnesses come from the
/// Bridge's session options, Chat's from the providers Hermes lists; each
/// lists only the models it runs, and what is saved and sent stays the
/// profile id or Hermes' model and provider.
final class LAAHarnessSelectionTests: XCTestCase {
    /// The live options' shape (bridge/src/sessions/options.mjs with the
    /// engine's provider states): codex's new sessions move to Pi, and Fast
    /// keeps them on Codex.
    private func options() throws -> LAAWorkSessionOptions {
        try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data(#"""
        {"profiles":[
          {"id":"opus-high","label":"Opus 5.5","provider":"claude","model":"claude-opus-5-5","effort":"high","fast":true,"harness":"claude"},
          {"id":"opus-xhigh","label":"Opus 5.5","provider":"claude","model":"claude-opus-5-5","effort":"xhigh","fast":true,"harness":"claude"},
          {"id":"mythos-high","label":"Mythos 5.2","provider":"claude","model":"claude-mythos-5-2","effort":"high","fast":false,"harness":"claude"},
          {"id":"sol-high","label":"GPT-6.2 Sol","provider":"codex","model":"gpt-6.2-sol","effort":"high","fast":true,"harness":"pi","fastHarness":"codex"},
          {"id":"sol-xhigh","label":"GPT-6.2 Sol","provider":"codex","model":"gpt-6.2-sol","effort":"xhigh","fast":true,"harness":"pi","fastHarness":"codex"},
          {"id":"terra-high","label":"GPT-6.1 Terra","provider":"codex","model":"gpt-6.1-terra","effort":"high","fast":true,"harness":"pi","fastHarness":"codex"},
          {"id":"dsh-high","label":"DeepSeek V4.1 Flash","provider":"dsh","model":"[\"opencode-go\",\"deepseek-v4.1-flash\"]","effort":"high","fast":false,"harness":"dsh"},
          {"id":"neon-high","label":"Gemini 4 Neon","provider":"antigravity","model":"gemini-4-neon","effort":"high","fast":false,"harness":"antigravity"},
          {"id":"opus-api-high","label":"Opus 5.5（API）","provider":"hermes-claude-api","model":"anthropic:claude-opus-5-5","effort":"high","fast":false}
        ],"defaultProfile":"opus-high","defaultMode":"bypass"}
        """#.utf8))
    }

    func testWorkHarnessesComeFromTheOptionsWithOnlyTheirOwnModels() throws {
        let options = try options()
        let groups = LAAWorkModelSelection.harnesses(LAAWorkModelSelection.models(options))
        XCTAssertEqual(groups.map(\.harness.name), ["Claude Code", "Pi", "DSH", "Antigravity", "Hermes", "Codex"])
        XCTAssertEqual(groups.map(\.fast), [false, false, false, false, false, true], "only Codex is reached by Fast")
        XCTAssertEqual(groups[0].models.map(\.label), ["Opus 5.5", "Mythos 5.2"])
        XCTAssertEqual(groups[1].models.map(\.model), ["gpt-6.2-sol", "gpt-6.1-terra"], "the moved provider is listed under Pi")
        XCTAssertEqual(groups[5].models.map(\.model), ["gpt-6.2-sol", "gpt-6.1-terra"])
        XCTAssertTrue(groups[4].metered, "a paid route is marked as billed")
        XCTAssertFalse(groups.prefix(4).contains(where: \.metered))
        // Every listed harness is one a profile starts on, and every model in it starts there.
        for group in groups {
            for model in group.models {
                let profile = try XCTUnwrap(model.profiles.first)
                XCTAssertEqual(LAAHarness.work(profile, fast: group.fast)?.id, group.harness.id, "\(group.harness.name) \(model.label)")
            }
        }
        // The default is never a metered route.
        let defaultGroup = LAAWorkModelSelection.group(of: try XCTUnwrap(options.defaultProfile), fast: false, in: groups)
        XCTAssertEqual(defaultGroup?.harness.kind, .claudeCode)
    }

    func testTheCurrentGroupFollowsFastWhereTheHarnessDependsOnIt() throws {
        let groups = LAAWorkModelSelection.harnesses(LAAWorkModelSelection.models(try options()))
        XCTAssertEqual(LAAWorkModelSelection.group(of: "sol-high", fast: false, in: groups)?.harness.kind, .pi)
        XCTAssertEqual(LAAWorkModelSelection.group(of: "sol-high", fast: true, in: groups)?.harness.kind, .codex)
        // Fast on a profile that is not moved keeps its harness.
        XCTAssertEqual(LAAWorkModelSelection.group(of: "opus-high", fast: true, in: groups)?.harness.kind, .claudeCode)
        XCTAssertNil(LAAWorkModelSelection.group(of: "gone", fast: false, in: groups))
    }

    /// A Bridge that predates `harness` names no move: each provider is its own harness.
    func testAnOlderBridgeFallsBackToTheProvider() throws {
        let options = try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data(#"""
        {"profiles":[
          {"id":"opus-high","label":"Opus 5.5","provider":"claude","model":"claude-opus-5-5","effort":"high","fast":true},
          {"id":"sol-high","label":"GPT-6.2 Sol","provider":"codex","model":"gpt-6.2-sol","effort":"high","fast":true}
        ],"defaultProfile":"opus-high","defaultMode":"bypass"}
        """#.utf8))
        let groups = LAAWorkModelSelection.harnesses(LAAWorkModelSelection.models(options))
        XCTAssertEqual(groups.map(\.harness.name), ["Claude Code", "Codex"])
        XCTAssertFalse(groups.contains(where: \.fast))
    }

    /// Picking under a harness keeps the saved shape: the profile id the
    /// launch body sends is one of the options' own, only the route changes.
    func testSwitchingHarnessKeepsTheProfileIdShape() throws {
        let options = try options()
        let groups = LAAWorkModelSelection.harnesses(LAAWorkModelSelection.models(options))
        let current = options.profiles[1]  // opus-xhigh
        let sol = try XCTUnwrap(groups.first { $0.harness.kind == .pi }?.models.first)
        let next = try XCTUnwrap(LAAWorkModelSelection.profile(switchingTo: sol, from: current))
        XCTAssertEqual(next.id, "sol-xhigh", "the effort is carried, as for any model change")
        XCTAssertTrue(options.profiles.contains(next))
        XCTAssertEqual(next.provider, "codex", "the launch body still names the provider")
        let encoded = LAAWorkModelPreferences.encode([.init(profile: next.id, fast: false)])
        XCTAssertEqual(LAAWorkModelPreferences.decode(encoded).first?.profile, "sol-xhigh")
    }

    func testWorkSessionHarnessDecodesAndOlderSessionsOmitIt() throws {
        XCTAssertEqual(LAAHarness.work("pi")?.kind, .pi)
        XCTAssertEqual(LAAHarness.work("claude-api")?.kind, .claudeCode)
        XCTAssertEqual(LAAHarness.work("pi-openai-api")?.kind, .pi)
        XCTAssertEqual(LAAHarness.work("dsh-refuseless")?.kind, .dsh)
        XCTAssertEqual(LAAHarness.work("echo")?.kind, .echo)
        XCTAssertNil(LAAHarness.work(nil))
        // One mark, not two: the model capsule drops its face only beside its own maker's harness.
        XCTAssertTrue(LAAHarness.work("claude")!.sharesMark(model: "claude-opus-5-5", provider: "claude"))
        XCTAssertFalse(LAAHarness.work("pi")!.sharesMark(model: "gpt-6.2-sol", provider: "codex"))
        XCTAssertFalse(LAAHarness.work("antigravity")!.sharesMark(model: "gemini-4-neon", provider: "antigravity"))
        XCTAssertTrue(LAAHarness.metered(workProvider: "claude-api"))
        XCTAssertFalse(LAAHarness.metered(workProvider: "claude"))
    }

    // MARK: Chat

    private func info(_ id: String) -> ModelInfo { ModelInfo(id: id, label: nil, reasoningCapable: true) }

    /// hq/logs/refuseless-route-20261126.md §1: Hermes hosts every chat; the
    /// provider decides what runs the turn.
    func testChatHarnessesFollowTheHermesRouteTable() {
        XCTAssertEqual(LAAHarness.chat(provider: "laa-agy").kind, .antigravity)
        XCTAssertEqual(LAAHarness.chat(provider: "custom:laa-agy").kind, .antigravity)
        XCTAssertEqual(LAAHarness.chat(provider: "claude-subscription-directsdk-experimental").kind, .claudeCode)
        XCTAssertEqual(LAAHarness.chat(provider: "laa-dsh").kind, .dsh)
        XCTAssertEqual(LAAHarness.chat(provider: "laa-monet-uncensored").kind, .dsh)
        XCTAssertEqual(LAAHarness.chat(provider: "openai-codex").kind, .hermes, "Hermes' own Codex route, not the Codex CLI")
        XCTAssertEqual(LAAHarness.chat(provider: "gpt-api").kind, .hermes)
        XCTAssertTrue(LAAHarness.metered(chatProvider: "gpt-api"))
        XCTAssertTrue(LAAHarness.metered(chatProvider: "custom:claude-api"))
        XCTAssertFalse(LAAHarness.metered(chatProvider: "openai-codex"))
        XCTAssertTrue(LAAHarness.metered(chatProvider: "laa-monet-uncensored"), "Refuseless is billed per use")
        // Muse and Dots run their own agents behind Hermes' custom rows: never labelled Hermes.
        XCTAssertEqual(LAAHarness.chat(provider: "custom:laa-muse").kind, .muse)
        XCTAssertEqual(LAAHarness.chat(provider: "custom:laa-dots").kind, .dots)
        XCTAssertEqual(LAAHarness.chat(provider: "custom:laa-muse").name, "Muse")
    }

    /// The Bridge marks a metered route (`metered`); the app follows it and
    /// keeps its own list only for an older Bridge. Claude Code and Pi on
    /// their API keys are their own harnesses, listed apart from the
    /// subscription models only by the mark.
    func testMeteredComesFromTheBridgeAndIsNeverTheDefault() throws {
        let options = try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data(#"""
        {"profiles":[
          {"id":"opus-high","label":"Opus 5.5","provider":"claude","model":"claude-opus-5-5","effort":"high","fast":true,"harness":"claude"},
          {"id":"opus-api-high","label":"Opus 5.5（API）","provider":"claude-api","model":"claude-opus-5-5","effort":"high","fast":false,"metered":true,"harness":"claude-api"},
          {"id":"sol-api-high","label":"GPT-6.2 Sol（API）","provider":"pi-openai-api","model":"gpt-6.2-sol","effort":"high","fast":false,"metered":true,"harness":"pi-openai-api"},
          {"id":"future-high","label":"Future","provider":"future-paid","model":"f","effort":"high","fast":false,"metered":true}
        ],"defaultProfile":"opus-high","defaultMode":"bypass"}
        """#.utf8))
        XCTAssertTrue(LAAWorkModelSelection.metered(options.profiles[1]))
        XCTAssertFalse(LAAWorkModelSelection.metered(options.profiles[0]))
        XCTAssertTrue(LAAWorkModelSelection.metered(options.profiles[3]), "an unknown provider the Bridge marks is metered")
        let groups = LAAWorkModelSelection.harnesses(LAAWorkModelSelection.models(options))
        let claude = groups.filter { $0.harness.kind == .claudeCode }
        XCTAssertEqual(claude.count, 1, "the API key is the same harness, one entry")
        XCTAssertFalse(claude[0].metered, "a harness with a subscription model is not marked as a whole")
        XCTAssertTrue(try XCTUnwrap(groups.first { $0.harness.kind == .pi }).metered)
        XCTAssertEqual(LAAWorkModelSelection.group(of: try XCTUnwrap(options.defaultProfile), fast: false, in: groups)?.harness.kind, .claudeCode)
        XCTAssertFalse(LAAWorkModelSelection.metered(try XCTUnwrap(options.profiles.first { $0.id == options.defaultProfile })))
        XCTAssertEqual(LAAHarness.work("muse")?.kind, .muse)
        XCTAssertEqual(LAAHarness.work("dots")?.name, "Dots")
    }

    func testChatHarnessesGroupOnlyWhatHermesOffersThisChat() {
        let slug = "claude-subscription-directsdk-experimental"
        let providers = [
            ProviderInfo(name: slug, models: ["claude-opus-5-5[1m]"].map(info)),
            ProviderInfo(name: "openai-codex", models: ["gpt-6.2-sol", "gpt-6.2-astra"].map(info)),
            ProviderInfo(name: "laa-dsh", models: ["deepseek-v4.1-flash"].map(info)),
            ProviderInfo(name: "laa-agy", models: ["gemini-4-neon"].map(info)),
            ProviderInfo(name: "gpt-api", models: ["openai-api:gpt-6.2-sol"].map(info)),
        ]
        let choices = LAAChatModelCatalog.choices(providers, visibility: ModelVisibility(),
                                                  runningModel: "gemini-4-neon", runningProvider: "laa-agy")
        let groups = LAAChatModelCatalog.harnesses(choices)
        XCTAssertEqual(groups.map(\.harness.name), ["Claude Code", "Hermes", "DSH", "Antigravity"])
        XCTAssertEqual(groups[0].choices.map(\.model), ["claude-mythos-5-2", "claude-opus-5-5[1m]"])
        XCTAssertEqual(groups[1].choices.map(\.provider), ["openai-codex", "openai-codex", "gpt-api"])
        XCTAssertEqual(LAAChatModelCatalog.sections(groups[1].choices).map(\.name), ["openai-codex", "GPT API"])
        XCTAssertTrue(LAAChatModelCatalog.meteredSection(groups[1].choices.filter { $0.provider == "gpt-api" }))
        XCTAssertFalse(LAAChatModelCatalog.meteredSection(groups[1].choices.filter { $0.provider == "openai-codex" }))
        // Every choice under a harness is switched through its own provider, so the harness is that route's.
        for group in groups {
            for choice in group.choices { XCTAssertEqual(LAAHarness.chat(provider: choice.provider).id, group.harness.id) }
        }
        // A hidden provider takes its harness out with it.
        var hidden = ModelVisibility()
        hidden.hiddenProviders = ["laa-dsh"]
        let fewer = LAAChatModelCatalog.choices(providers, visibility: hidden, runningModel: nil, runningProvider: nil)
        XCTAssertFalse(LAAChatModelCatalog.harnesses(fewer).contains { $0.harness.kind == .dsh })
        XCTAssertTrue(LAAChatModelCatalog.harnesses([]).isEmpty)
    }
}
#endif
