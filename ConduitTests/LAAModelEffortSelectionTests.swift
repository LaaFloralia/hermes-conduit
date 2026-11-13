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

    // MARK: - Standing and the one movement (owner, 2026-11-14: no colour, glass and a quiet light)

    func testStandingIsTheNumberOfMetalLinesNotAColour() {
        XCTAssertEqual(LAAModelRank.of("claude-mythos-5-2").finish, .double)
        XCTAssertEqual(LAAModelRank.of("claude-fable-5-2[1m]").finish, .line)
        XCTAssertEqual(LAAModelRank.of("gpt-6-astra").finish, .line)
        for plain in ["claude-opus-5-5", "claude-sonnet-5-5", "gpt-6.1-sol", "gpt-6.1-terra",
                      #"["opencode-go","deepseek-v4.1-flash"]"#, "laa-router"] {
            XCTAssertEqual(LAAModelRank.of(plain).finish, .plain, plain)
        }
        XCTAssertEqual(LAAModelRank.of(nil).finish, .plain)
        XCTAssertEqual(["low", "medium", "high", "xhigh", "max"].map { LAAEffort.finish($0).lines }, [0, 0, 0, 1, 2])
        XCTAssertEqual(LAAEffort.finish("minimal"), .plain)
        XCTAssertEqual(LAAEffort.finish(nil), .plain)
        XCTAssertTrue(LAAFinish.plain < .line && LAAFinish.line < .double)
    }

    func testEachMovementIsOneOfTheHouseDurations() {
        XCTAssertEqual(LAAEffort.order.compactMap { LAACeremony.motion(effort: $0) }, [.breath, .breath, .pass, .trace, .trace])
        XCTAssertEqual(LAAEffort.order.map { LAACeremony.duration(effort: $0) }, [0.22, 0.22, 0.30, 0.42, 0.42])
        XCTAssertNil(LAACeremony.motion(effort: "minimal"), "an effort outside the five never moves")
        XCTAssertEqual(LAACeremony.duration(effort: "minimal"), 0)
        XCTAssertEqual(LAACeremony.motion(rank: .none), .breath)
        for rank in [LAAModelRank.mythos, .fable, .astra] {
            XCTAssertEqual(LAACeremony.motion(rank: rank), .trace)
            XCTAssertEqual(LAACeremony.duration(rank: rank), 0.42)
        }
        XCTAssertEqual(LAACeremony.duration(rank: .none), 0.22)
    }

    func testTheRimRestsWithItsLinesAndNoLight() {
        for finish in [LAAFinish.plain, .line, .double] {
            for motion in [LAACeremony.Motion.breath, .pass, .trace] {
                for elapsed in [nil, LAACeremony.duration(motion), 5] as [Double?] {
                    let look = LAARimLook(finish: finish, motion: motion, elapsed: elapsed)
                    XCTAssertFalse(look.live)
                    XCTAssertEqual(look.outer, finish.lines >= 1 ? 1 : 0)
                    XCTAssertEqual(look.inner, finish.lines >= 2 ? 1 : 0)
                    XCTAssertNil(look.light, "no light at rest")
                    XCTAssertEqual(look.lightOpacity, 0)
                    XCTAssertEqual(look.breath, 0)
                }
            }
        }
    }

    func testATraceDrawsTheLinesBehindTheLightOnce() {
        var lastOuter = -1.0, lastInner = -1.0
        for step in 0..<42 {
            let look = LAARimLook(finish: .double, motion: .trace, elapsed: Double(step) / 100)
            XCTAssertTrue(look.live)
            guard let light = look.light else { return XCTFail("a trace has its light at \(step)") }
            XCTAssertEqual(look.outer, light.upperBound, accuracy: 1e-9, "the outer line ends at the light's head")
            XCTAssertLessThanOrEqual(light.upperBound - light.lowerBound, LAACeremony.lightLength + 1e-9)
            XCTAssertLessThanOrEqual(look.inner, look.outer + 1e-9, "the inner line follows")
            XCTAssertGreaterThanOrEqual(look.outer, lastOuter)
            XCTAssertGreaterThanOrEqual(look.inner, lastInner)
            XCTAssertLessThanOrEqual(look.lightOpacity, 1)
            XCTAssertEqual(look.breath, 0)
            lastOuter = look.outer; lastInner = look.inner
        }
        XCTAssertGreaterThan(lastOuter, 0.99, "the light has gone all the way round by the end")
        let mid = LAARimLook(finish: .line, motion: .trace, elapsed: 0.2)
        XCTAssertEqual(mid.inner, 0, "a single line has no inner line")
        XCTAssertEqual(mid.lightOpacity, 1)
    }

    func testAPassLeavesNothingAndABreathOnlyBrightensTheEdge() {
        let pass = LAARimLook(finish: .plain, motion: .pass, elapsed: 0.15)
        XCTAssertNotNil(pass.light)
        XCTAssertEqual(pass.outer, 0)
        XCTAssertEqual(pass.breath, 0)
        let breath = LAARimLook(finish: .plain, motion: .breath, elapsed: 0.11)
        XCTAssertNil(breath.light, "a breath has no travelling light")
        XCTAssertEqual(breath.breath, 1, accuracy: 1e-9, "brightest halfway")
        XCTAssertEqual(LAARimLook(finish: .plain, motion: .breath, elapsed: 0).breath, 0, accuracy: 1e-9)
    }

    func testTheLightSetsOffFromTheLeadingEndOverTheTop() {
        let rect = CGRect(x: 0, y: 0, width: 140, height: 36)
        let rim = LAARimPath(cornerRadius: 18, inset: 0.5).path(in: rect)
        let start = rim.trimmedPath(from: 0, to: 0.005).boundingRect
        XCTAssertLessThan(start.midX, 2, "at the leading end")
        XCTAssertEqual(start.midY, rect.midY, accuracy: 1.5, "at its middle")
        let soon = rim.trimmedPath(from: 0.15, to: 0.16).boundingRect
        XCTAssertLessThan(soon.midY, 2, "then along the top")
        let half = rim.trimmedPath(from: 0.49, to: 0.51).boundingRect
        XCTAssertGreaterThan(half.midX, rect.maxX - 2, "half way round is the trailing end")
        let inner = LAARimPath(cornerRadius: 18, inset: LAARimFinish.innerInset + 0.5).path(in: rect).boundingRect
        XCTAssertEqual(inner.minX, 4.5, accuracy: 0.01, "the inner line sits a spacing step inside")
    }

    func testTheMeterIsInkAndRisesWithinItsMovement() {
        let rest = LAAEffortLook(effort: "max")
        XCTAssertEqual(rest.level, 5)
        XCTAssertEqual((0..<5).map { rest.tickScale($0) }, [1, 1, 1, 1, 1])
        XCTAssertEqual(LAAEffortLook(effort: "xhigh").rim.finish, .line)
        XCTAssertEqual(LAAEffortLook(effort: "max").rim.finish, .double)
        XCTAssertEqual(LAAEffortLook(effort: "max", current: false).rim.finish, .plain, "a last-confirmed value has no finish")
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
