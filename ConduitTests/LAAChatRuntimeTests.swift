#if LAA_BUILD
import XCTest
@testable import Conduit

/// The chat composer's model · effort chip reads what Hermes reports for the
/// running agent (`session.info`), in the shapes it really sends, and says
/// 「不明」 for anything missing.
final class LAAChatRuntimeTests: XCTestCase {
    private func report(_ object: [String: AnyCodable], for session: String, into runtime: inout LAAChatRuntime) {
        let snapshot = SessionRuntimeSnapshot(object: object)
        runtime.apply(sessionID: session, model: snapshot.model, provider: snapshot.provider,
                      effort: snapshot.reasoningEffort)
    }

    func testAstraOffersOnlySupportedRouteEffortsAfterSwitch() {
        XCTAssertEqual(LAAChatModelCatalog.efforts(current: "high", model: "gpt-6-astra", provider: "openai-codex"),
                       ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(LAAChatModelCatalog.efforts(current: "high", model: "claude-mythos-5-2", provider: "claude"), LAAEffort.order)
    }

    func testModelAndEffortAsHermesReportsThem() {
        var runtime = LAAChatRuntime()
        report(["model": .string("deepseek-v4.1-flash"), "provider": .string("laa-dsh"),
                "reasoning_effort": .string("high"), "running": .bool(false)], for: "a", into: &runtime)
        XCTAssertEqual(runtime.shown(for: ["a"]),
                       .init(model: "deepseek-v4.1-flash", provider: "laa-dsh", effort: "high"))
    }

    /// Hermes sends `"reasoning_effort": ""` when the agent has no level of
    /// its own (the provider's default): that is unknown, not a guess.
    func testAModelWithoutAnEffortShowsUnknownEffort() {
        var runtime = LAAChatRuntime()
        report(["model": .string("claude-opus-5-5"), "provider": .string("claude"),
                "reasoning_effort": .string("")], for: "a", into: &runtime)
        XCTAssertEqual(runtime.shown(for: ["a"]), .init(model: "claude-opus-5-5", provider: "claude", effort: nil))
    }

    /// A dormant chat's info carries neither.
    func testNeitherReportedShowsUnknownForBoth() {
        var runtime = LAAChatRuntime()
        report(["model": .string(""), "provider": .string(""), "reasoning_effort": .string("")], for: "a", into: &runtime)
        XCTAssertEqual(runtime.shown(for: ["a"]), .init(model: nil, provider: nil, effort: nil))
        var silent = LAAChatRuntime()
        report(["running": .bool(true)], for: "a", into: &silent)
        XCTAssertEqual(silent.shown(for: ["a"]), .init(model: nil, provider: nil, effort: nil))
    }

    /// Another employee's chat never shows the previous chat's values, and
    /// a later report (a model switch mid-chat) replaces them.
    func testValuesFollowTheChatAndItsChanges() {
        var runtime = LAAChatRuntime()
        report(["model": .string("claude-opus-5-5"), "provider": .string("claude"),
                "reasoning_effort": .string("high")], for: "monet", into: &runtime)
        XCTAssertEqual(runtime.shown(for: ["ada"]), .init(model: nil, provider: nil, effort: nil))
        report(["model": .string("deepseek-v4.1-flash"), "provider": .string("laa-dsh"),
                "reasoning_effort": .string("high")], for: "ada", into: &runtime)
        XCTAssertEqual(runtime.shown(for: ["ada"]).model, "deepseek-v4.1-flash")
        // A status without the model keeps the model and takes the effort.
        report(["reasoning_effort": .string("xhigh")], for: "ada", into: &runtime)
        XCTAssertEqual(runtime.shown(for: ["ada"]),
                       .init(model: "deepseek-v4.1-flash", provider: "laa-dsh", effort: "xhigh"))
        // Known by any of the chat's ids (runtime and stored).
        XCTAssertEqual(runtime.shown(for: ["stored-ada", "ada"]).effort, "xhigh")
    }
}
#endif
