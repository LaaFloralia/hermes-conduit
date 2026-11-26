#if LAA_BUILD
import UIKit
import XCTest
@testable import Conduit

/// Model and effort are chosen apart (owner, 2026-11-12): another model keeps
/// the effort when it has it, else High, else the nearest; nothing is
/// guessed when a value or the choices are unknown.
final class LAAModelEffortSelectionTests: XCTestCase {
    private func profile(_ id: String, _ provider: String, _ model: String, _ label: String, _ effort: String,
                         fast: Bool = false) -> LAAWorkSessionOptions.Profile {
        .init(id: id, label: label, provider: provider, model: model, effort: effort, fast: fast)
    }

    private var options: LAAWorkSessionOptions {
        .init(profiles: [
            profile("opus-high", "claude", "claude-opus-5-5", "Claude Opus 5.5", "high", fast: true),
            profile("opus-xhigh", "claude", "claude-opus-5-5", "Claude Opus 5.5", "xhigh", fast: true),
            profile("mythos-high", "claude", "claude-mythos-5-2", "Claude Mythos 5.2", "high"),
            profile("astra-max", "codex", "gpt-6-astra", "GPT-6 Astra", "max", fast: true),
            profile("astra-xhigh", "codex", "gpt-6-astra", "GPT-6 Astra", "xhigh", fast: true),
            profile("dsh-low", "dsh", "deepseek-v4.1-flash", "DeepSeek V4.1 Flash", "low"),
        ], defaultProfile: "opus-high", defaultMode: "bypass")
    }

    func testCarriedEffort() {
        XCTAssertEqual(LAAEffort.carried("xhigh", into: ["high", "xhigh"]), "xhigh", "the same effort stays")
        XCTAssertEqual(LAAEffort.carried("xhigh", into: ["low", "high"]), "high", "else High")
        XCTAssertEqual(LAAEffort.carried("high", into: ["xhigh", "max"]), "xhigh", "else the nearest")
        XCTAssertEqual(LAAEffort.carried("low", into: ["medium", "max"]), "medium")
        XCTAssertEqual(LAAEffort.carried("high", into: ["medium", "xhigh"]), "medium", "a tie takes the lower")
        XCTAssertEqual(LAAEffort.carried(nil, into: ["max", "medium"]), "medium", "unknown counts as High")
        XCTAssertEqual(LAAEffort.carried("minimal", into: ["low", "max"]), "low")
        XCTAssertNil(LAAEffort.carried("high", into: []), "no effort offered, none chosen")
    }

    func testModelsGroupTheProfilesInTableOrder() {
        let models = LAAWorkModelSelection.models(options)
        XCTAssertEqual(models.map(\.label), ["Opus 5.5", "Mythos 5.2", "GPT-6 Astra", "DeepSeek V4.1 Flash"])
        XCTAssertEqual(models[2].efforts, ["xhigh", "max"], "lowest effort first")
        XCTAssertEqual(LAAWorkModelSelection.providers(models).map(\.name), ["Claude", "GPT", "DeepSeek"])
        XCTAssertTrue(LAAWorkModelSelection.models(nil).isEmpty)
    }

    func testSwitchingModelKeepsTheProfileIdShape() throws {
        let models = LAAWorkModelSelection.models(options)
        let opusXHigh = options.profiles[1]
        XCTAssertEqual(LAAWorkModelSelection.profile(switchingTo: models[2], from: opusXHigh)?.id, "astra-xhigh")
        XCTAssertEqual(LAAWorkModelSelection.profile(switchingTo: models[1], from: opusXHigh)?.id, "mythos-high")
        XCTAssertEqual(LAAWorkModelSelection.profile(switchingTo: models[3], from: opusXHigh)?.id, "dsh-low",
                       "a model with one effort takes it")
        XCTAssertEqual(LAAWorkModelSelection.profile(switchingTo: models[0], from: nil)?.id, "opus-high")
        XCTAssertEqual(LAAWorkModelSelection.profile(effort: "xhigh", of: "opus-high", in: options)?.id, "opus-xhigh")
        XCTAssertNil(LAAWorkModelSelection.profile(effort: "max", of: "opus-high", in: options))
        XCTAssertNil(LAAWorkModelSelection.model(of: "gone", in: options))
    }

    func testChatChoicesFollowHermesAndTheHiddenModels() {
        let providers = [
            ProviderInfo(name: "claude", models: [ModelInfo(id: "claude-opus-5-5", label: nil, reasoningCapable: true),
                                                  ModelInfo(id: "claude-mythos-5-2", label: nil, reasoningCapable: true),
                                                  ModelInfo(id: "local-tts", label: "Voice", reasoningCapable: false)],
                         displayName: "Claude"),
            ProviderInfo(name: "venice", models: [ModelInfo(id: "uncensored", label: "Uncensored", reasoningCapable: false)]),
        ]
        var hidden = ModelVisibility()
        hidden.hiddenModels = ["claude\u{1F}local-tts"]
        hidden.hiddenProviders = ["venice"]
        let choices = LAAChatModelCatalog.choices(providers, visibility: hidden,
                                                  runningModel: "claude-opus-5-5", runningProvider: "claude")
        XCTAssertEqual(choices.map(\.label), ["Opus 5.5", "Mythos 5.2"])
        XCTAssertEqual(choices.filter(\.current).map(\.model), ["claude-opus-5-5"])
        XCTAssertEqual(LAAChatModelCatalog.sections(choices).map(\.name), ["Claude"])
        let all = LAAChatModelCatalog.choices(providers, visibility: ModelVisibility(), runningModel: nil, runningProvider: nil)
        XCTAssertEqual(all.map(\.label), ["Opus 5.5", "Mythos 5.2", "Voice", "Uncensored"])
        XCTAssertTrue(all.allSatisfy { !$0.current }, "nothing is checked when Hermes reported no model")
    }

    /// The Claude CLI's picker, where Hermes reads the subscription's models,
    /// does not name Mythos yet; Hermes switches to it by id. Fable is no
    /// longer added (owner, 2026-11-23: Mythos takes its part).
    func testTheClaudeSubscriptionOffersMythosAheadOfItsListedModels() {
        let slug = "claude-subscription-directsdk-experimental"
        let listed = [ModelInfo(id: "claude-opus-5-5[1m]", label: nil, reasoningCapable: true),
                      ModelInfo(id: "claude-fable-5-1[1m]", label: nil, reasoningCapable: true)]
        let providers = [ProviderInfo(name: slug, models: listed, displayName: "Claude Subscription"),
                         ProviderInfo(name: "anthropic", models: [ModelInfo(id: "claude-opus-5-5", label: nil, reasoningCapable: true)])]
        let choices = LAAChatModelCatalog.choices(providers, visibility: ModelVisibility(),
                                                  runningModel: "claude-mythos-5-2", runningProvider: slug)
        XCTAssertEqual(choices.map(\.label), ["Mythos 5.2", "Opus 5.5", "Fable 5.1", "Opus 5.5"])
        XCTAssertEqual(choices.first?.model, "claude-mythos-5-2")
        XCTAssertFalse(choices.contains { $0.model == "claude-fable-5-2" }, "Fable is not added")
        XCTAssertEqual(choices.filter(\.current).map(\.model), ["claude-mythos-5-2"], "the running model is checked though unlisted")
        XCTAssertTrue(choices.prefix(1).allSatisfy { $0.provider == slug && $0.reasoning })
        // Once the picker names one, or the owner hides one, it is not added again.
        let named = [ProviderInfo(name: slug, models: listed + [ModelInfo(id: "claude-mythos-5-2[1m]", label: nil, reasoningCapable: true)])]
        XCTAssertEqual(LAAChatModelCatalog.choices(named, visibility: ModelVisibility(), runningModel: nil, runningProvider: nil).map(\.model),
                       ["claude-opus-5-5[1m]", "claude-fable-5-1[1m]", "claude-mythos-5-2[1m]"])
        var hidden = ModelVisibility()
        hidden.hiddenModels = ["\(slug)\u{1F}claude-mythos-5-2"]
        XCTAssertEqual(LAAChatModelCatalog.choices(providers, visibility: hidden, runningModel: nil, runningProvider: nil).map(\.model),
                       ["claude-opus-5-5[1m]", "claude-fable-5-1[1m]", "claude-opus-5-5"])
    }

    /// Hermes lists every model its routes know; Chat offers only the ones the
    /// Work catalog names (owner, 2026-11-23: the latest of each tier). The
    /// chat's running model stays, so a chat on an old one carries on.
    func testChatOffersOnlyTheWorkCatalogsLineup() throws {
        let options = try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data(#"""
        {"profiles":[
          {"id":"opus-high","label":"Opus 5.5","provider":"claude","model":"claude-opus-5-5","effort":"high","fast":false},
          {"id":"mythos-high","label":"Mythos 5.2","provider":"claude","model":"claude-mythos-5-2","effort":"high","fast":false},
          {"id":"sol-high","label":"GPT-6.2 Sol","provider":"codex","model":"gpt-6.2-sol","effort":"high","fast":true},
          {"id":"astra-high","label":"GPT-6.2 Astra","provider":"codex","model":"gpt-6.2-astra","effort":"high","fast":true},
          {"id":"dsh-high","label":"DeepSeek","provider":"dsh","model":"[\"opencode-go\",\"deepseek-v4.1-flash\"]","effort":"high","fast":false},
          {"id":"neon-high","label":"Gemini 4 Neon","provider":"antigravity","model":"gemini-4-neon","effort":"high","fast":false},
          {"id":"gptapi-high","label":"GPT-6.2 Sol（API）","provider":"hermes-openai-api","model":"openai-api:gpt-6.2-sol","effort":"high","fast":false}
        ],"defaultProfile":"opus-high","defaultMode":"bypass"}
        """#.utf8))
        let lineup = try XCTUnwrap(LAAChatModelAllowList(options: options))
        func info(_ id: String) -> ModelInfo { ModelInfo(id: id, label: nil, reasoningCapable: true) }
        let slug = "claude-subscription-directsdk-experimental"
        let providers = [
            ProviderInfo(name: slug, models: ["claude-opus-5-5[1m]", "claude-fable-5-2[1m]", "claude-opus-4-8", "claude-sonnet-4-5-20250929"].map(info)),
            ProviderInfo(name: "openai-codex", models: ["gpt-6.2-sol", "gpt-6.1-sol", "gpt-6-astra", "gpt-6.2-astra", "gpt-5.5"].map(info)),
            ProviderInfo(name: "laa-dsh", models: ["deepseek-v4.1-flash", "deepseek-v4-pro"].map(info)),
            ProviderInfo(name: "laa-agy", models: ["gemini-4-neon-high", "gemini-3-pro"].map(info)),
            ProviderInfo(name: "gpt-api", models: ["openai-api:gpt-6.2-sol", "openai-api:gpt-5.5"].map(info)),
        ]
        let shown = LAAChatModelCatalog.choices(providers, visibility: ModelVisibility(), runningModel: "gpt-6.1-sol",
                                                runningProvider: "openai-codex", allowed: lineup)
        XCTAssertEqual(shown.map(\.model), ["claude-mythos-5-2", "claude-opus-5-5[1m]",
                                             "gpt-6.2-sol", "gpt-6.1-sol", "gpt-6.2-astra",
                                             "deepseek-v4.1-flash", "gemini-4-neon-high", "openai-api:gpt-6.2-sol"])
        XCTAssertEqual(shown.filter(\.current).map(\.model), ["gpt-6.1-sol"], "the chat's old model stays and is checked")
        XCTAssertFalse(shown.contains { $0.label.contains("Fable") })
        // Without a lineup, Hermes' list is shown as it is.
        let unfiltered = LAAChatModelCatalog.choices(providers, visibility: ModelVisibility(), runningModel: nil, runningProvider: nil)
        XCTAssertEqual(unfiltered.count, 1 + providers.map(\.models.count).reduce(0, +))
        // Ids from different routes meet.
        XCTAssertEqual(LAAChatModelAllowList.key(#"["opencode-go","deepseek-v4.1-flash"]"#), "deepseek-v4-1-flash")
        XCTAssertEqual(LAAChatModelAllowList.key("anthropic:claude-opus-5-5"), "claude-opus-5-5")
        XCTAssertEqual(LAAChatModelAllowList.key("claude-opus-5-5[1m]"), "claude-opus-5-5")
        XCTAssertEqual(LAAChatModelAllowList.key("anthropic/claude-opus-5.5"), "claude-opus-5-5")
        XCTAssertEqual(LAAChatModelAllowList.key("claude-sonnet-5-5-20261001"), "claude-sonnet-5-5")
        XCTAssertFalse(lineup.allows("claude-sonnet-4-5-20250929"))
    }

    /// Hermes' real `model.options` for Monet (2026-11-23, C2): the Codex and
    /// Claude subscription rows carry every old model; the lineup keeps the
    /// latest of each tier, and Mythos is added to the subscription.
    func testHermesRealListNarrowsToTheLineup() {
        let catalog = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-mythos-5-2",
                       "gpt-6.2-sol", "gpt-6.1-terra", "gpt-6-luna", "gpt-6.2-astra",
                       #"["opencode-go","deepseek-v4.1-flash"]"#, #"["venice","deepseek-v4-1-flash-1017-uncensored"]"#,
                       "anthropic:claude-opus-5-5", "openai-api:gpt-6.2-sol", "gemini-4-neon", "gemini-4-hydrogen", "dots"]
        let lineup = LAAChatModelAllowList(keys: Set(catalog.map(LAAChatModelAllowList.key)))
        let rows: [(String, [String])] = [
            ("openai-codex", ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-terra", "gpt-6.1-sol", "gpt-6.1-sol-900k", "gpt-6-astra", "gpt-6-astra-900k", "gpt-6-sol", "gpt-6-sol-900k", "gpt-6-luna", "gpt-6-luna-900k", "gpt-5.6-sol", "gpt-5.6-sol-900k", "gpt-5.6-terra", "gpt-5.6-terra-900k", "gpt-5.6-luna", "gpt-5.6-luna-900k"]),
            ("laa-agy", ["gemini-4-neon", "gemini-4-hydrogen"]),
            ("laa-dsh", ["deepseek-v4.1-flash", "deepseek-v4-1-flash-1017-uncensored"]),
            ("claude-subscription-directsdk-experimental", ["claude-sonnet-5-5[1m]", "claude-sonnet-5[1m]", "claude-haiku-5-5[1m]", "claude-haiku-4-5-20251001", "claude-opus-5-5[1m]", "claude-opus-5[1m]", "claude-opus-4-8[1m]", "claude-fable-5-1[1m]", "claude-fable-5-2"]),
            ("gpt-api", ["gpt-6.2-sol", "gpt-6.1-terra", "gpt-6-luna", "gpt-6.2-astra"]),
            ("claude-api", ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-mythos-5-2"])
        ]
        let providers = rows.map { name, ids in
            ProviderInfo(name: name, models: ids.map { ModelInfo(id: $0, label: nil, reasoningCapable: true) })
        }
        let shown = LAAChatModelCatalog.choices(providers, visibility: ModelVisibility(), runningModel: "gemini-4-neon",
                                                runningProvider: "laa-agy", allowed: lineup)
        let byProvider = Dictionary(grouping: shown, by: \.provider).mapValues { $0.map(\.model) }
        XCTAssertEqual(byProvider["openai-codex"], ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-terra", "gpt-6-luna"])
        XCTAssertEqual(byProvider["claude-subscription-directsdk-experimental"],
                       ["claude-mythos-5-2", "claude-sonnet-5-5[1m]", "claude-haiku-5-5[1m]", "claude-opus-5-5[1m]"])
        XCTAssertEqual(byProvider["gpt-api"]?.count, 4)
        XCTAssertEqual(byProvider["claude-api"]?.count, 4)
        XCTAssertEqual(byProvider["laa-agy"], ["gemini-4-neon", "gemini-4-hydrogen"])
        XCTAssertFalse(shown.contains { $0.model.contains("fable") || $0.model.contains("900k") || $0.model.hasPrefix("gpt-5") })
    }

    /// C2's union of the five replies (2026-11-23): Codex still lists older
    /// GPT 5 names; `-900k` is never offered, even with no lineup read or
    /// beside the newest name; the uncensored model only in its own chat.
    /// What is sent stays Hermes' raw id.
    func testOlderCodexNamesLongContextAndUncensoredAreLeftOut() {
        let lineup = LAAChatModelAllowList(keys: Set(["gpt-6.2-sol", "gpt-6.2-sol-900k", "deepseek-v4.1-flash",
                                                      #"["venice","deepseek-v4-1-flash-1017-uncensored"]"#,
                                                      "claude-opus-5-5"].map(LAAChatModelAllowList.key)))
        let providers = [
            ProviderInfo(name: "openai-codex", models: ["gpt-6.2-sol", "gpt-6.2-sol-900k", "gpt-5.3-codex-spark", "gpt-5.4",
                                                        "gpt-5.4-900k", "gpt-5.4-mini", "gpt-5.5"]
                .map { ModelInfo(id: $0, label: nil, reasoningCapable: true) }),
            ProviderInfo(name: "laa-dsh", models: ["deepseek-v4.1-flash", "deepseek-v4-1-flash-1017-uncensored"]
                .map { ModelInfo(id: $0, label: nil, reasoningCapable: true) }),
            ProviderInfo(name: "claude-subscription-directsdk-experimental",
                         models: [ModelInfo(id: "claude-opus-5-5[1m]", label: nil, reasoningCapable: true)]),
        ]
        func shown(_ allowed: LAAChatModelAllowList?, _ profile: String) -> [String] {
            LAAChatModelCatalog.choices(providers, visibility: ModelVisibility(), runningModel: nil, runningProvider: nil,
                                        allowed: allowed, profile: profile).map(\.model)
        }
        let employee = shown(lineup, "laa-cto")
        XCTAssertEqual(employee.filter { $0.hasPrefix("gpt") }, ["gpt-6.2-sol"])
        XCTAssertFalse(employee.contains { $0.contains("uncensored") })
        XCTAssertTrue(employee.contains("claude-opus-5-5[1m]"), "matched without [1m], sent with it")
        XCTAssertTrue(shown(lineup, "laa-monet-uncensored").contains("deepseek-v4-1-flash-1017-uncensored"))
        XCTAssertFalse(shown(nil, "laa-cto").contains { $0.hasSuffix("-900k") || $0.contains("uncensored") },
                       "with no lineup kept, these two rules still hold")
    }

    /// The lineup read last is kept on the device for when the Bridge cannot
    /// be read; nothing kept means no filter.
    @MainActor func testTheLineupIsKeptOnTheDevice() throws {
        let suite = "laa.test.lineup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); LAAChatModelAllowList.resetForTesting() }
        LAAChatModelAllowList.resetForTesting()
        XCTAssertNil(LAAChatModelAllowList.current(defaults))
        let options = try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data(#"""
        {"profiles":[{"id":"sol-high","label":"GPT-6.2 Sol","provider":"codex","model":"gpt-6.2-sol","effort":"high","fast":true}],
         "defaultProfile":"sol-high","defaultMode":"bypass"}
        """#.utf8))
        LAAChatModelAllowList.record(options, defaults: defaults)
        LAAChatModelAllowList.resetForTesting()
        XCTAssertEqual(LAAChatModelAllowList.current(defaults)?.keys, ["gpt-6-2-sol"], "read back from the device after a restart")
        // An empty catalog does not replace the kept lineup.
        LAAChatModelAllowList.record(try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data(#"{"profiles":[],"defaultProfile":null,"defaultMode":null}"#.utf8)),
                                     defaults: defaults)
        XCTAssertEqual(LAAChatModelAllowList.current(defaults)?.keys, ["gpt-6-2-sol"])
    }

    func testChatLocksSayWhy() {
        let one = LAAChatModelCatalog.Choice(model: "dots", provider: "custom", providerName: "Dots", label: "Dots",
                                             reasoning: false, current: true)
        typealias C = LAAChatModelCatalog
        XCTAssertEqual(C.modelLock(sessionID: nil, connected: true, phase: .ready([one, one]), switching: false),
                       "会話を始めると変更できます。")
        XCTAssertEqual(C.modelLock(sessionID: "a", connected: false, phase: .idle, switching: false), "Hermesに接続していません。")
        XCTAssertEqual(C.modelLock(sessionID: "a", connected: true, phase: .failed, switching: false),
                       "モデルの候補を取得できませんでした。")
        XCTAssertEqual(C.modelLock(sessionID: "a", connected: true, phase: .ready([one]), switching: false),
                       "この社員で選べるモデルはこれだけです。")
        XCTAssertEqual(C.modelLock(sessionID: "a", connected: true, phase: .ready([]), switching: false), "選べるモデルがありません。")
        XCTAssertNil(C.modelLock(sessionID: "a", connected: true, phase: .ready([one, one]), switching: false))
        XCTAssertEqual(C.effortLock(sessionID: "a", connected: true, current: one, writing: false),
                       "このモデルは推論の強さを変えられません。")
        XCTAssertNil(C.effortLock(sessionID: "a", connected: true, current: nil, writing: false))
        XCTAssertEqual(C.efforts(current: "minimal"), LAAEffort.order + ["minimal"], "a reported level outside the five is listed")
        XCTAssertEqual(C.efforts(current: nil), LAAEffort.order)
    }

    func testStandingIsMarbleByStepWithMythosTheStrongest() {
        XCTAssertEqual(LAAModelRank.of("claude-mythos-5-2").step, .model)
        // Fable left the lineup (owner, 2026-11-23): an old chat on it reads plain.
        XCTAssertEqual(LAAModelRank.of("claude-fable-5-2").step, .plain)
        XCTAssertEqual(LAAModelRank.of("gpt-6.2-astra").step, .model)
        XCTAssertEqual(LAAModelRank.of("claude-opus-5-5").step, .plain, "owner, 2026-11-14 22:00: Opus is plain glass")
        XCTAssertEqual(LAAModelRank.of("gpt-6.1-sol").step, .plain)
        XCTAssertEqual(LAAModelRank.of("deepseek-v4.1-flash").step, .plain)
        XCTAssertEqual(LAAModelRank.of(nil).step, .plain)
        // Gemini 4 Neon wears the model step in the house 青緑 (2026-11-23); Hydrogen is plain.
        XCTAssertEqual(LAAModelRank.of("gemini-4-neon"), .neon)
        XCTAssertEqual(LAAModelRank.of("Gemini 4 Neon"), .neon)
        XCTAssertEqual(LAAModelRank.of("gemini-4-neon").step, .model)
        XCTAssertEqual(LAAModelRank.neon.tone, .neon)
        XCTAssertEqual(LAAModelRank.of("gemini-4-hydrogen").step, .plain)
        XCTAssertNotEqual(LAAVeinTone.neon.tokens, LAAVeinTone.mythos.tokens, "Neon reads apart from Mythos")
        XCTAssertGreaterThan(LAASelectionStyle(tone: .mythos, step: .model).intensity,
                             LAASelectionStyle(tone: .neon, step: .model).intensity, "Mythos stays the strongest")
        XCTAssertEqual(LAAEffort.step("medium"), .plain)
        XCTAssertEqual(LAAEffort.step("high"), .plain, "High and below stay plain")
        XCTAssertEqual(LAAEffort.step("xhigh"), .xhigh)
        XCTAssertEqual(LAAEffort.step("max"), .max)
        XCTAssertEqual(LAAEffort.step("ultracode"), .ultracode)
        XCTAssertEqual(LAAEffort.name("ultracode"), "Ultra Code")
        XCTAssertEqual(LAAModelRank.mythos.tone, .mythos)
        XCTAssertEqual(LAAModelRank.astra.tone, .astra)
        XCTAssertEqual(LAAModelRank.none.tone, .stone)
        // Mythos > Astra = Neon; XHigh < Max < Ultra Code (appSelection).
        let mythos = LAASelectionStyle(tone: .mythos, step: .model)
        let astra = LAASelectionStyle(tone: .astra, step: .model), neon = LAASelectionStyle(tone: .neon, step: .model)
        XCTAssertGreaterThan(mythos.intensity, astra.intensity)
        XCTAssertEqual(astra.intensity, neon.intensity)
        let xhigh = LAASelectionStyle(tone: .stone, step: .xhigh), max = LAASelectionStyle(tone: .stone, step: .max)
        let ultra = LAASelectionStyle(tone: .stone, step: .ultracode)
        XCTAssertLessThan(xhigh.intensity, max.intensity)
        XCTAssertLessThan(max.intensity, ultra.intensity)
        XCTAssertLessThan(ultra.tileSize.width, max.tileSize.width, "the higher step is denser")
        XCTAssertLessThanOrEqual(max.tileSize.width, xhigh.tileSize.width)
        XCTAssertTrue(LAASelectionStyle(tone: .mythos, step: .plain).isPlain)
        for dark in [false, true] {
            XCTAssertEqual(LAAMarbleLook(step: .plain).veinOpacity(dark: dark), 0, "plain glass holds no vein")
            XCTAssertEqual(LAAMarbleLook(step: .plain).glowOpacity(dark: dark), 0)
            XCTAssertGreaterThan(mythos.lightOpacity(dark: dark), astra.lightOpacity(dark: dark))
            XCTAssertGreaterThan(ultra.hairOpacity(dark: dark), xhigh.hairOpacity(dark: dark))
            XCTAssertLessThanOrEqual(ultra.veinOpacity(LAAAppSelectionTokens.mainOpacity, dark: dark), 1)
        }
    }

    /// The label band reaches the chevron and drops the vein under it
    /// (design review 2026-11-15).
    func testTheLabelBandCoversTheChevron() {
        let band = LAAMarble.labelBand(width: 120)
        XCTAssertEqual(band.locations.count, band.opacities.count)
        XCTAssertEqual(band.locations, band.locations.sorted())
        let chevron = Double((120 - 16) / 120.0)
        let index = band.locations.lastIndex { $0 <= chevron } ?? 0
        XCTAssertEqual(band.opacities[index], LAAAppSelectionTokens.labelBandChevron)
        XCTAssertLessThanOrEqual(LAAMarble.driftFrameRate, 24)
    }

    @MainActor
    func testUltraCodeCapsuleKeepsItsRankedStepOutsideTheFiveGeneralEfforts() {
        let capsule = LAAEffortCapsule(effort: "ultracode")
        XCTAssertEqual(capsule.ranked, "ultracode")
        XCTAssertEqual(LAAEffort.step(capsule.ranked), .ultracode)
        XCTAssertFalse(LAAEffort.order.contains("ultracode"))
        XCTAssertNil(LAAEffortCapsule(effort: "unknown").ranked)
    }

    func testAnAppliedChangeSpreadsTheVeinsOnceFromTheLeadingEnd() {
        let d = LAAAppSelectionTokens.selectionSeconds
        let start = LAAMarbleLook(step: .max, elapsed: 0, duration: d)
        let middle = LAAMarbleLook(step: .max, elapsed: d * 0.4, duration: d)
        let end = LAAMarbleLook(step: .max, elapsed: d, duration: d)
        XCTAssertLessThan(start.front!, 0, "the veins spread from beyond the leading end")
        XCTAssertGreaterThan(middle.front!, start.front!)
        XCTAssertEqual(middle.lightAt, middle.front!, "the light rides the front")
        XCTAssertNil(end.front, "once over, every vein shows")
        XCTAssertEqual(end.lightAt, LAAMarble.restLight, "and the light rests")
        XCTAssertEqual(LAAMarbleLook(step: .plain, elapsed: d * 0.4, duration: d).glowOpacity(dark: true), 0,
                       "plain glass holds no light, not even in the front")
        XCTAssertGreaterThan(LAACeremony.duration(rank: .mythos), LAACeremony.duration(rank: .none), "Mythos takes the slow time")
        XCTAssertLessThanOrEqual(LAACeremony.duration(rank: .mythos), LAACeremony.slow)
    }

    /// The capsules wrap whole: a row too narrow for both puts the effort on
    /// the next line rather than cutting the model's name (owner, 2026-11-14).
    func testCapsulesWrapWholeAndTheComposerGivesThemALine() {
        XCTAssertEqual(LAAWrapRow.lines([180, 110, 64], available: nil, spacing: 8), [0, 0, 0])
        XCTAssertEqual(LAAWrapRow.lines([180, 110, 64], available: 340, spacing: 8), [0, 0, 1])
        XCTAssertEqual(LAAWrapRow.lines([180, 110, 64], available: 250, spacing: 8), [0, 1, 1])
        XCTAssertEqual(LAAWrapRow.lines([300, 110], available: 250, spacing: 8), [0, 1], "a capsule wider than the row keeps a line")
        typealias Row = LAAComposerControlsRow
        XCTAssertTrue(Row.oneLine(lead: 36, middle: 220, trail: 80, available: 400, spacing: 8))
        XCTAssertFalse(Row.oneLine(lead: 36, middle: 340, trail: 80, available: 400, spacing: 8))
        XCTAssertTrue(Row.oneLine(lead: 36, middle: 340, trail: 80, available: nil, spacing: 8))
    }

    /// Gemini (Google AI Pro via Antigravity) and the GPT API in Work's menu
    /// (2026-11-23), under their own headings, Neon and Hydrogen by name.
    func testWorkOffersGeminiAndTheGPTAPIUnderTheirRoutes() {
        let options = LAAWorkSessionOptions(profiles: [
            profile("opus-high", "claude", "claude-opus-5-5", "Claude Opus 5.5", "high"),
            profile("neon-high", "antigravity", "gemini-4-neon", "Gemini 4 Neon", "high"),
            profile("neon-low", "antigravity", "gemini-4-neon", "Gemini 4 Neon", "low"),
            profile("hydrogen-xhigh", "antigravity", "gemini-4-hydrogen", "Gemini 4 Hydrogen", "xhigh"),
            profile("gpt-api-high", "hermes-openai-api", "openai-api:gpt-5.5", "GPT-5.5（API）", "high"),
            profile("opus-api-high", "hermes-claude-api", "anthropic:claude-opus-5-5", "Claude Opus 5.5（API）", "high"),
        ], defaultProfile: "opus-high", defaultMode: "bypass")
        let models = LAAWorkModelSelection.models(options)
        XCTAssertEqual(models.map(\.label), ["Opus 5.5", "Gemini 4 Neon", "Gemini 4 Hydrogen", "GPT-5.5（API）", "Opus 5.5（API）"])
        XCTAssertEqual(models[1].efforts, ["low", "high"])
        XCTAssertEqual(LAAWorkModelSelection.providers(models).map(\.name), ["Claude", "Gemini", "GPT API", "Claude API"])
        XCTAssertEqual(LAAModelFace.face(model: "gemini-4-hydrogen", provider: "antigravity"), .gemini)
        XCTAssertEqual(LAAModelFace.face(model: "openai-api:o3", provider: "hermes-openai-api"), .gpt(.other))
    }

    /// Hermes' providers for Gemini (`laa-agy`), the GPT API (`gpt-api`) and
    /// the Claude API (`claude-api`) read as LAA names them; Gemini offers Low
    /// to XHigh, and Muse and Dots (no Chat model since the contractors left
    /// Chat on 2026-11-26) are offered to no one.
    func testChatReadsGeminiAndTheAPIsAndKeepsMuseAndDotsToTheirEmployees() {
        let providers = [
            ProviderInfo(name: "laa-agy", models: [
                ModelInfo(id: "gemini-4-neon", label: nil, reasoningCapable: true),
                ModelInfo(id: "gemini-4-hydrogen", label: nil, reasoningCapable: true)], displayName: "laa-agy"),
            ProviderInfo(name: "gpt-api", models: [ModelInfo(id: "gpt-5.5", label: nil, reasoningCapable: true),
                                                   ModelInfo(id: "o3", label: nil, reasoningCapable: true)], displayName: "GPT API"),
            ProviderInfo(name: "claude-api", models: [ModelInfo(id: "claude-opus-5-5", label: nil, reasoningCapable: true)],
                         displayName: "Claude API"),
            ProviderInfo(name: "custom:laa-dots", models: [ModelInfo(id: "dots", label: "Dots", reasoningCapable: false)]),
            ProviderInfo(name: "custom:laa-muse", models: [ModelInfo(id: "muse", label: "Muse", reasoningCapable: false)]),
        ]
        let choices = LAAChatModelCatalog.choices(providers, visibility: ModelVisibility(), runningModel: nil, runningProvider: nil)
        XCTAssertEqual(choices.map(\.label), ["Gemini 4 Neon", "Gemini 4 Hydrogen", "GPT 5.5", "o3", "Opus 5.5"])
        XCTAssertEqual(LAAChatModelCatalog.sections(choices).map(\.name), ["Gemini", "GPT API", "Claude API"])
        // The dedicated employee still sees its own model.
        let dots = LAAChatModelCatalog.choices(providers, visibility: ModelVisibility(), runningModel: "dots", runningProvider: "custom:laa-dots")
        XCTAssertEqual(dots.filter(\.current).map(\.model), ["dots"])
        XCTAssertFalse(dots.contains { $0.model == "muse" })
        XCTAssertEqual(LAAChatModelCatalog.efforts(current: "high", model: "gemini-4-neon", provider: "antigravity"),
                       ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(LAAChatModelCatalog.efforts(current: "max", model: "gemini-4-neon"), ["low", "medium", "high", "xhigh", "max"],
                       "a reported level outside Gemini's four is listed")
        XCTAssertEqual(LAAModelCapsule.readableName("gemini-4-neon-high"), "Gemini 4 Neon")
        XCTAssertEqual(LAAModelCapsule.readableName("openai-api:gpt-5.4-mini"), "GPT 5.4 Mini")
        XCTAssertEqual(LAAModelCapsule.readableName("gpt-6.1-sol"), "GPT 6.1 Sol")
        XCTAssertEqual(LAAModelCapsule.displayName(model: "anthropic:claude-opus-5-5", provider: "hermes-claude-api"), "Claude Opus 5.5")
        XCTAssertEqual(LAAModelDisplay.name("openai-api:gpt-5.5"), "GPT-5.5")
        XCTAssertEqual(LAAModelDisplay.name("gemini-4-neon"), "Gemini 4 Neon")
    }

    func testCapsuleNamesAreWholeAndBeginWithTheirMaker() {
        XCTAssertEqual(LAAModelCapsule.text(model: "claude-mythos-5-2", provider: "claude", name: nil, current: true),
                       "Claude Mythos 5.2")
        XCTAssertEqual(LAAModelCapsule.text(model: "claude-opus-5-5", provider: "claude", name: "Opus 5.5", current: true),
                       "Claude Opus 5.5", "a short table label gets its maker")
        XCTAssertEqual(LAAModelCapsule.text(model: "gpt-6-astra", provider: "openai-codex", name: "GPT 6 Astra", current: true),
                       "GPT 6 Astra")
        XCTAssertEqual(LAAModelCapsule.text(model: nil, provider: nil, name: nil, current: false), "最終確認 不明")
        XCTAssertEqual(LAAModelCapsule.text(model: nil, provider: nil, name: "モデルを選択", current: true), "モデルを選択")
        XCTAssertEqual(LAAModelCapsule.displayName(model: "laa-monet-local", provider: "claude"), "Claude")
        XCTAssertEqual(LAAModelCapsule.displayName(model: "gpt-6.1-sol", provider: "codex"), "GPT 6.1 Sol")
        XCTAssertEqual(LAAModelCapsule.displayName(model: #"["opencode-go","deepseek-v4.1-flash"]"#, provider: "dsh"),
                       "DeepSeek V4.1 Flash")
        XCTAssertEqual(LAAModelCapsule.displayName(model: "deepseek-v4.1-pro", provider: "dsh"), "DeepSeek V4.1 Pro",
                       "each DeepSeek model by its own name")
        XCTAssertNil(LAAModelCapsule.readableName("laa-monet-local"))
        XCTAssertEqual(LAAModelCapsule.readableName("claude-opus-5-5[1m]"), "Opus 5.5", "the 1M route reads as its model")
        XCTAssertEqual(LAAModelCapsule.displayName(model: "claude-opus-5-5[1m]", provider: "claude"), "Claude Opus 5.5")
    }
}
#endif
