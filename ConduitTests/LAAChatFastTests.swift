#if LAA_BUILD
import XCTest
@testable import Conduit

/// The chat composer's Fast capsule: it shows the speed Hermes reported for
/// the chat on screen, offers what the model has, and Monet · Dots reads a
/// fixed Astra · Max · Ultrafast with nothing to choose.
final class LAAChatFastTests: XCTestCase {
    private func display(_ speed: ModelSpeed?, fast: Bool? = true, ultrafast: Bool = false, session: String? = "s",
                         connected: Bool = true, writable: Bool = true, writing: Bool = false) -> LAAChatFastControl.Display? {
        LAAChatFastControl.display(speed: speed, capability: fast.map { .init(fast: $0, ultrafast: ultrafast) },
                                   sessionID: session, connected: connected, writable: writable, writing: writing)
    }

    func testSpeedIsKeptAgainstTheChatItWasReportedFor() {
        var runtime = LAAChatRuntime()
        XCTAssertNil(runtime.shown(for: ["monet"]).speed)
        runtime.applySpeed(sessionID: "monet", fast: true, serviceTier: "priority")
        XCTAssertEqual(runtime.shown(for: ["monet"]).speed, .fast)
        // Another chat reads unknown, not the previous chat's speed.
        XCTAssertNil(runtime.shown(for: ["ada"]).speed)
        runtime.applySpeed(sessionID: "monet", fast: true, serviceTier: "ultrafast")
        XCTAssertEqual(runtime.shown(for: ["monet"]).speed, .ultrafast)
        // A report without `fast` keeps the value; `fast: false` is normal.
        runtime.applySpeed(sessionID: "monet", fast: nil, serviceTier: nil)
        XCTAssertEqual(runtime.shown(for: ["monet"]).speed, .ultrafast)
        runtime.applySpeed(sessionID: "monet", fast: false, serviceTier: nil)
        XCTAssertEqual(runtime.shown(for: ["monet"]).speed, .normal)
        // The model and effort are untouched by a speed report.
        XCTAssertEqual(runtime.shown(for: ["monet"]), .init(model: nil, provider: nil, effort: nil, speed: .normal))
    }

    func testHiddenUntilReportedAndWhenTheModelHasNoFast() {
        XCTAssertNil(display(nil))
        XCTAssertNil(display(.normal, fast: false))
        // A gateway that says nothing about the model still shows the value.
        XCTAssertNotNil(display(.normal, fast: nil))
        // A reported Fast is shown even when the row claims none.
        XCTAssertEqual(display(.fast, fast: false)?.speed, .fast)
    }

    func testTogglesWithoutUltrafastAndListsThreeWithIt() {
        let plain = display(.normal)
        XCTAssertEqual(plain?.choices, [.normal, .fast])
        XCTAssertEqual(plain?.toggles, true)
        XCTAssertEqual(plain?.on, false)
        XCTAssertEqual(LAAChatFastControl.toggled(.normal), .fast)
        XCTAssertEqual(LAAChatFastControl.toggled(.fast), .normal)
        XCTAssertEqual(LAAChatFastControl.toggled(.ultrafast), .normal)

        let offered = display(.fast, ultrafast: true)
        XCTAssertEqual(offered?.choices, [.normal, .fast, .ultrafast])
        XCTAssertEqual(offered?.toggles, false)
        // Ultrafast already on lists the three even if the row no longer offers it.
        XCTAssertEqual(display(.ultrafast)?.choices, [.normal, .fast, .ultrafast])
    }

    func testLocksSayWhyAndOpenAMenu() {
        XCTAssertEqual(display(.normal, session: nil)?.lock, "会話を始めると変更できます。")
        XCTAssertEqual(display(.normal, connected: false)?.lock, "Hermesに接続していません。")
        XCTAssertEqual(display(.normal, writable: false)?.lock, "この会話ではFastを変更できません。")
        XCTAssertEqual(display(.normal, writing: true)?.lock, "変更中です。")
        XCTAssertEqual(display(.normal, writing: true)?.toggles, false)
        XCTAssertNil(display(.normal)?.lock)
    }

    func testWordsAndNames() {
        XCTAssertEqual(ModelSpeed.allCases.map(LAAChatFastControl.name), ["通常", "Fast", "Ultrafast"])
        XCTAssertEqual(ModelSpeed.allCases.map(LAAChatFastControl.word), ["Fast", "Fast", "Ultrafast"])
    }

    func testCapabilityIsReadForTheRunningModelOfItsProvider() throws {
        let row = try XCTUnwrap(ProviderInfo(from: AnyCodable(jsonObject: [
            "slug": "openai-codex", "models": ["gpt-6-astra", "gpt-6.1-terra"],
            "capabilities": ["gpt-6-astra": ["fast": true, "ultrafast": true], "gpt-6.1-terra": ["fast": true]],
        ])))
        let other = ProviderInfo(name: "claude", models: [ModelInfo(id: "claude-opus-5-5", label: nil, reasoningCapable: true)],
                                 displayName: "Claude")
        XCTAssertEqual(LAAChatFastControl.capability([other, row], model: "gpt-6-astra", provider: "openai-codex")?.fast, true)
        XCTAssertEqual(LAAChatFastControl.capability([other, row], model: "GPT-6-Astra", provider: "openai-codex")?.fast, true)
        XCTAssertNil(LAAChatFastControl.capability([other, row], model: "claude-opus-5-5", provider: "claude"))
        XCTAssertNil(LAAChatFastControl.capability([other, row], model: "gpt-6-astra", provider: "laa-dsh"))
        XCTAssertNil(LAAChatFastControl.capability([other, row], model: nil, provider: "openai-codex"))
    }

    func testOnlyMonetDotsIsFixedAndReadsAstraUltraCodeFastOn() {
        let fixed = LAAChatFixedRuntime.of(profile: "laa-monet-dots")
        XCTAssertEqual(fixed, .dots)
        XCTAssertEqual(fixed?.name, "GPT 6 Astra")
        XCTAssertEqual(LAAModelCapsule.displayName(model: fixed?.model, provider: fixed?.provider), "GPT 6 Astra")
        XCTAssertEqual(LAAEffort.name(fixed?.effort), "Ultra Code")
        XCTAssertEqual(fixed?.fast.speed, .fast)
        // Nothing to choose, and the menu says why.
        XCTAssertEqual(fixed?.fast.choices, [])
        XCTAssertEqual(fixed?.fast.toggles, false)
        XCTAssertEqual(fixed?.fast.lock, "Monet（Dots）はモデルと推論を選べません。")
        for profile in ["laa-monet", "laa-monet-uncensored", "laa-cto", "default", ""] {
            XCTAssertNil(LAAChatFixedRuntime.of(profile: profile), profile)
        }
    }
}
#endif
