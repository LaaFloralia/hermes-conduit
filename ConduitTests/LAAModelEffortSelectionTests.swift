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

    func testStandingIsLightAndMaterialNeverColour() {
        XCTAssertEqual(LAAModelRank.of("claude-mythos-5-2").finish, .crystal)
        XCTAssertEqual(LAAModelRank.of("claude-fable-5-2").finish, .polished)
        XCTAssertEqual(LAAModelRank.of("gpt-6-astra").finish, .polished)
        XCTAssertEqual(LAAModelRank.of("claude-opus-5-5").finish, .plain, "owner, 2026-11-14 22:00: Opus has no particles")
        XCTAssertEqual(LAAModelRank.of("gpt-6.1-sol").finish, .plain)
        XCTAssertEqual(LAAModelRank.of("gpt-6.1-terra").finish, .plain)
        XCTAssertEqual(LAAModelRank.of("deepseek-v4.1-flash").finish, .plain)
        XCTAssertEqual(LAAModelRank.of(nil).finish, .plain)
        XCTAssertEqual(LAAEffort.finish("medium"), .plain)
        XCTAssertEqual(LAAEffort.finish("high"), .plain, "XHigh and above hold particles")
        XCTAssertEqual(LAAEffort.finish("xhigh"), .polished)
        XCTAssertEqual(LAAEffort.finish("max"), .crystal)
        XCTAssertEqual(LAAEffort.name("ultracode"), "Ultra Code")
        for dark in [false, true] {
            let plain = LAAGlassLook(finish: .plain)
            let polished = LAAGlassLook(finish: .polished), crystal = LAAGlassLook(finish: .crystal)
            XCTAssertEqual(plain.topLight(dark: dark), 0, "plain glass holds no light of its own")
            XCTAssertEqual(plain.body(dark: dark), 0)
            XCTAssertEqual(plain.glint(dark: dark), 0)
            XCTAssertGreaterThan(polished.topLight(dark: dark), 0)
            XCTAssertGreaterThan(crystal.topLight(dark: dark), polished.topLight(dark: dark), "Mythos holds the most light")
            XCTAssertGreaterThan(crystal.body(dark: dark), polished.body(dark: dark), "and is the densest glass")
            XCTAssertLessThan(crystal.body(dark: dark), 0.1, "the glass stays clear")
            XCTAssertGreaterThan(crystal.glint(dark: dark), polished.glint(dark: dark))
            XCTAssertGreaterThan(crystal.glintLength, polished.glintLength)
            XCTAssertEqual(polished.counterGlint(dark: dark), 0, "only the crystal catches the light twice")
            XCTAssertGreaterThan(crystal.counterGlint(dark: dark), 0)
        }
    }

    /// The particles (owner, 2026-11-14 21:45): none in plain glass, more and
    /// brighter at each step, all inside the capsule, and none at all when the
    /// glass is still (Reduce Motion, Low Power Mode).
    func testParticlesGrowWithTheStepAndStayInsideTheGlass() {
        let size = CGSize(width: 180, height: 36)
        func average(_ finish: LAAFinish) -> (count: Double, alpha: Double) {
            var count = 0, alpha = 0.0
            for frame in 0..<48 {
                let grains = LAAGlassLook(finish: finish, time: 100 + Double(frame) / 4).grains(in: size)
                count += grains.count
                alpha += grains.map(\.alpha).reduce(0, +)
                for grain in grains {
                    XCTAssert((0...size.width).contains(CGFloat(grain.x)) && (0...size.height).contains(CGFloat(grain.y)),
                              "\(grain) lies outside the glass")
                    XCTAssert((0...1).contains(grain.alpha))
                }
            }
            return (Double(count) / 48, alpha / Double(max(count, 1)))
        }
        XCTAssertEqual(average(.plain).count, 0, "plain glass holds no particle")
        let polished = average(.polished), crystal = average(.crystal)
        XCTAssertGreaterThan(polished.count, 4)
        XCTAssertGreaterThan(crystal.count, polished.count)
        XCTAssertGreaterThan(crystal.alpha, polished.alpha)
        XCTAssertLessThan(crystal.count, 40, "a few dozen at most: a light drawing")
        XCTAssertTrue(LAAGlassLook(finish: .crystal, time: nil).grains(in: size).isEmpty, "still glass draws none")
        let a = LAAGlassLook(finish: .crystal, time: 12).grains(in: size)
        XCTAssertEqual(a, LAAGlassLook(finish: .crystal, time: 12).grains(in: size), "any moment draws the same")
        XCTAssertNotEqual(a, LAAGlassLook(finish: .crystal, time: 12.5).grains(in: size), "and they drift")
    }

    @MainActor
    func testUltraCodeCapsuleKeepsItsRankedFinishOutsideTheFiveGeneralEfforts() {
        let capsule = LAAEffortCapsule(effort: "ultracode")
        XCTAssertEqual(capsule.ranked, "ultracode")
        XCTAssertEqual(LAAEffort.finish(capsule.ranked), .crystal)
        XCTAssertFalse(LAAEffort.order.contains("ultracode"))
        XCTAssertNil(LAAEffortCapsule(effort: "unknown").ranked)
    }

    func testOneFrontOfLightCrossesTheGlassAndTheStandingSettlesBehindIt() {
        let d = LAACeremony.slow
        let start = LAAGlassLook(finish: .crystal, elapsed: 0, duration: d)
        let middle = LAAGlassLook(finish: .crystal, elapsed: d * 0.4, duration: d)
        let end = LAAGlassLook(finish: .crystal, elapsed: d, duration: d)
        XCTAssertLessThan(start.front!, 0, "the light enters from beyond the leading end")
        XCTAssertGreaterThan(middle.front!, start.front!)
        XCTAssertGreaterThan(middle.frontStrength, 0.9)
        XCTAssertLessThan(start.topLight(dark: false), middle.topLight(dark: false), "the standing light settles behind the front")
        XCTAssertNil(end.front, "once over, nothing moves but the particles")
        XCTAssertEqual(end.topLight(dark: false), LAAGlassLook(finish: .crystal).topLight(dark: false))
        let size = CGSize(width: 120, height: 36)
        let plain = LAAGlassLook(finish: .plain, elapsed: d * 0.4, duration: d, time: 3)
        XCTAssertTrue(plain.grains(in: size).isEmpty, "plain glass holds no particle, not even in the front")
        let polished = LAAGlassLook(finish: .polished, elapsed: d * 0.4, duration: d, time: 3)
        let burst = polished.grains(in: size).count - LAAGlassLook(finish: .polished, time: 3).grains(in: size).count
        XCTAssertGreaterThan(burst, 0, "the front carries a burst of its own")
        XCTAssertLessThan(polished.frontStrength, middle.frontStrength, "the crystal's front is the strongest")
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
        let dots = LAAChatFixedRuntime.dots
        XCTAssertEqual(LAAModelCapsule.text(model: dots.model, provider: dots.provider, name: dots.name, current: true), "GPT 6 Astra")
    }
}
#endif
