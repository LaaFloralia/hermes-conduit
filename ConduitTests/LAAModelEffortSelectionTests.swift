#if LAA_BUILD
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
    /// names neither yet; Hermes switches to them by id.
    func testTheClaudeSubscriptionOffersFableAndMythosAheadOfItsListedModels() {
        let slug = "claude-subscription-directsdk-experimental"
        let listed = [ModelInfo(id: "claude-opus-5-5[1m]", label: nil, reasoningCapable: true),
                      ModelInfo(id: "claude-fable-5-1[1m]", label: nil, reasoningCapable: true)]
        let providers = [ProviderInfo(name: slug, models: listed, displayName: "Claude Subscription"),
                         ProviderInfo(name: "anthropic", models: [ModelInfo(id: "claude-opus-5-5", label: nil, reasoningCapable: true)])]
        let choices = LAAChatModelCatalog.choices(providers, visibility: ModelVisibility(),
                                                  runningModel: "claude-mythos-5-2", runningProvider: slug)
        XCTAssertEqual(choices.map(\.label), ["Fable 5.2", "Mythos 5.2", "Opus 5.5", "Fable 5.1", "Opus 5.5"])
        XCTAssertEqual(choices.prefix(2).map(\.model), ["claude-fable-5-2", "claude-mythos-5-2"])
        XCTAssertEqual(choices.filter(\.current).map(\.model), ["claude-mythos-5-2"], "the running model is checked though unlisted")
        XCTAssertTrue(choices.prefix(2).allSatisfy { $0.provider == slug && $0.reasoning })
        // Once the picker names one, or the owner hides one, it is not added again.
        let named = [ProviderInfo(name: slug, models: listed + [ModelInfo(id: "claude-fable-5-2[1m]", label: nil, reasoningCapable: true)])]
        var hidden = ModelVisibility()
        hidden.hiddenModels = ["\(slug)\u{1F}claude-mythos-5-2"]
        XCTAssertEqual(LAAChatModelCatalog.choices(named, visibility: hidden, runningModel: nil, runningProvider: nil).map(\.model),
                       ["claude-opus-5-5[1m]", "claude-fable-5-1[1m]", "claude-fable-5-2[1m]"])
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

    func testModelAndEffortUseTwoStrengthsOfGlassTint() {
        XCTAssertEqual(LAAModelRank.of("claude-mythos-5-2").finish, .intense)
        XCTAssertEqual(LAAModelRank.of("claude-fable-5-2").finish, .tinted)
        XCTAssertEqual(LAAModelRank.of("gpt-6-astra").finish, .tinted)
        XCTAssertEqual(LAAModelRank.of(nil).finish, .plain)
        XCTAssertEqual(LAAEffort.finish("high"), .plain)
        XCTAssertEqual(LAAEffort.finish("xhigh"), .tinted)
        XCTAssertEqual(LAAEffort.finish("max"), .intense)
        XCTAssertEqual(LAAEffort.name("ultracode"), "Ultra Code")
        for dark in [false, true] {
            let regular = LAALiquidLook(finish: .tinted).opacity(dark: dark)
            let strong = LAALiquidLook(finish: .intense).opacity(dark: dark)
            XCTAssertGreaterThan(strong, regular)
            XCTAssertGreaterThan(regular, 0)
            XCTAssertLessThan(strong, 0.5, "glass remains translucent")
        }
    }

    func testColourSettlesAfterOneSpreadAndNeverMarksAnUnknownValue() {
        let start = LAALiquidLook(finish: .intense, elapsed: 0)
        let middle = LAALiquidLook(finish: .intense, elapsed: 0.21)
        let end = LAALiquidLook(finish: .intense, elapsed: 0.42)
        XCTAssertLessThan(start.spread, middle.spread)
        XCTAssertGreaterThan(middle.bloom, 0.9)
        XCTAssertEqual(end.bloom, 0)
        XCTAssertEqual(end.opacity(dark: false), LAALiquidLook(finish: .intense).opacity(dark: false))
        for t in [0.0, 0.1, 0.3, 0.42] {
            XCTAssertEqual(LAALiquidLook(finish: .plain, elapsed: t).opacity(dark: true), 0)
        }
    }

    func testTheMeterIsInkAndRisesWithinItsMovement() {
        let rest = LAAEffortLook(effort: "max")
        XCTAssertEqual(rest.level, 5)
        XCTAssertEqual((0..<5).map { rest.tickScale($0) }, [1, 1, 1, 1, 1])
        XCTAssertEqual(LAAEffortLook(effort: "xhigh").finish, .tinted)
        XCTAssertEqual(LAAEffortLook(effort: "max").finish, .intense)
        XCTAssertEqual(LAAEffortLook(effort: "max", current: false).finish, .plain, "a last-confirmed value has no finish")
        XCTAssertNil(LAAEffortLook(effort: "low").tick(1), "Low fills one tick")
        let rising = LAAEffortLook(effort: "max", elapsed: 0.05)
        XCTAssertLessThan(rising.tickScale(4), rising.tickScale(0), "one after another")
        let end = LAAEffortLook(effort: "max", elapsed: LAACeremony.duration(effort: "max") - 0.001)
        XCTAssertEqual(end.tickScale(4), 1, accuracy: 0.02, "the last tick is up before the movement ends")
        XCTAssertEqual(LAAEffortLook(effort: "max", current: false, elapsed: 0.05).tickScale(0), 1, "a last-confirmed value never moves")
    }

    func testCapsuleNames() {
        XCTAssertEqual(LAAModelCapsule.text(model: "claude-mythos-5-2", provider: "claude", name: nil, current: true), "Mythos 5.2")
        XCTAssertEqual(LAAModelCapsule.text(model: nil, provider: nil, name: nil, current: false), "最終確認 不明")
        XCTAssertEqual(LAAModelCapsule.displayName(model: "laa-monet-local", provider: "claude"), "Claude")
        XCTAssertNil(LAAModelCapsule.readableName("laa-monet-local"))
        XCTAssertEqual(LAAModelCapsule.readableName("claude-opus-5-5[1m]"), "Opus 5.5", "the 1M route reads as its model")
    }
}
#endif
