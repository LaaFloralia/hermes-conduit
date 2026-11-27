#if LAA_BUILD && DEBUG
import AVFAudio
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

@MainActor final class LAAChatProjectTests: XCTestCase {
    func testSeedOnceCRUDAndRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "projects.json")
        let store = LAAChatProjectStore(fileURL: file)
        XCTAssertEqual(store.projects.map(\.model), [.hydrogen, .hydrogen])
        XCTAssertEqual(store.projects.map(\.name), ["Instant", "Pokémon Size Marks"])
        let id = try store.create(name: " 趣味 ", context: "# Notes", model: .deepSeek)
        XCTAssertEqual(store.project(id)?.name, "趣味")
        try store.edit(id, name: "名前", context: "**preset**")
        let input = LAAChatProject.Message(role: .user, text: "質問")
        try store.reserve(input, in: id)
        XCTAssertEqual(LAAChatProjectStore(fileURL: file).project(id)?.pending, input)
        try store.complete(input, answer: "答え", in: id)
        try store.complete(input, answer: "重複", in: id)
        for seed in LAAChatProjectStore.seeds { try store.delete(seed.id) }
        let relaunched = LAAChatProjectStore(fileURL: file)
        XCTAssertEqual(relaunched.projects.map(\.id), [id])
        XCTAssertEqual(relaunched.project(id)?.context, "**preset**")
        XCTAssertEqual(relaunched.project(id)?.history.map(\.text), ["質問", "答え"])
        XCTAssertNil(relaunched.project(id)?.pending)
        try relaunched.delete(id)
        XCTAssertTrue(LAAChatProjectStore(fileURL: file).projects.isEmpty)
    }

    func testModelSelectionPreservesRoutesHistoryAndPendingWork() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "projects.json")
        let store = LAAChatProjectStore(fileURL: file)
        let id = LAAChatProjectStore.instantID
        let question = LAAChatProject.Message(role: .user, text: "What is 2+2?")
        try store.reserve(question, in: id)
        XCTAssertThrowsError(try store.selectModel(.deepSeek, in: id))
        try store.complete(question, answer: "4", in: id)
        try store.selectModel(.deepSeek, in: id)
        let first = try XCTUnwrap(store.project(id))
        let deepSeekID = first.conversationID(for: .deepSeek)
        XCTAssertNotEqual(deepSeekID, id)
        XCTAssertEqual(first.history.map(\.text), [question.text, "4"])
        XCTAssertEqual(first.history.last?.model, .hydrogen)
        let relaunched = LAAChatProjectStore(fileURL: file)
        XCTAssertEqual(relaunched.project(id), first)
        try relaunched.selectModel(.hydrogen, in: id)
        XCTAssertEqual(relaunched.project(id)?.conversationID(for: .hydrogen), id)
        try relaunched.selectModel(.deepSeek, in: id)
        XCTAssertEqual(relaunched.project(id)?.conversationID(for: .deepSeek), deepSeekID)
    }

    func testPokemonMigrationLoadsWithoutRewritingOpaqueCustomDataAndKeepsLegacyReplay() throws {
        struct Archive: Encodable { let schema = 1; let projects: [LAAChatProject] }
        let file = FileManager.default.temporaryDirectory.appending(path: "project-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let id = LAAChatProjectStore.pokemonID
        let question = LAAChatProject.Message(role: .user, text: "Past question")
        let answer = LAAChatProject.Message(role: .assistant, text: "Past answer")
        let pending = LAAChatProject.Message(role: .user, text: "Unconfirmed question")
        let pokemon = LAAChatProject(id: id, name: "Edited name", context: "Edited context", model: .deepSeek,
                                     kind: .pokemon, history: [question, answer], pending: pending)
        let customMessage = LAAChatProject.Message(role: .user, text: "Custom history")
        let custom = LAAChatProject(name: "ポケモンサイズ証判定", context: "My rules", model: .deepSeek,
                                    history: [customMessage])
        let encoded = try JSONEncoder().encode(Archive(projects: [custom, pokemon]))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var records = try XCTUnwrap(root["projects"] as? [[String: Any]])
        var history = try XCTUnwrap(records[0]["history"] as? [[String: Any]])
        history[0]["opaqueMessage"] = ["tags": ["retain", "me"]]
        records[0]["history"] = history
        records[0]["opaqueProject"] = ["revision": 9, "metadata": NSNull()]
        root["projects"] = records
        root["opaqueArchive"] = [true, false]
        let original = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try original.write(to: file)

        let store = LAAChatProjectStore(fileURL: file)
        XCTAssertFalse(store.unavailable)
        let migrated = try XCTUnwrap(store.project(id))
        XCTAssertEqual(migrated.model, .hydrogen)
        XCTAssertEqual(migrated.kind, .pokemon)
        XCTAssertEqual(migrated.name, pokemon.name)
        XCTAssertEqual(migrated.context, pokemon.context)
        XCTAssertEqual(migrated.history.map(\.id), [question.id, answer.id])
        XCTAssertEqual(migrated.history.map(\.text), [question.text, answer.text])
        XCTAssertEqual(migrated.history.last?.model, .deepSeek)
        XCTAssertEqual(migrated.pending, pending)
        XCTAssertEqual(migrated.pendingModel, .deepSeek)
        XCTAssertEqual(migrated.pendingConversationID, id)
        XCTAssertNotEqual(migrated.conversationID(for: migrated.model), id)
        XCTAssertEqual(store.project(custom.id), custom)
        XCTAssertEqual(try Data(contentsOf: file), original, "First load must not rewrite the archive")

        let reopened = LAAChatProjectStore(fileURL: file)
        XCTAssertEqual(reopened.projects, store.projects)
        XCTAssertEqual(try Data(contentsOf: file), original, "Relaunch must not rewrite the archive")
        try reopened.complete(pending, answer: "Recovered once", in: id)
        let next = LAAChatProject.Message(role: .user, text: "New question")
        try reopened.reserve(next, in: id)
        let hydrogenID = migrated.conversationID(for: .hydrogen)
        let withPending = LAAChatProjectStore(fileURL: file)
        XCTAssertEqual(withPending.project(id)?.pending, next)
        XCTAssertEqual(withPending.project(id)?.pendingModel, .hydrogen)
        XCTAssertEqual(withPending.project(id)?.pendingConversationID, hydrogenID)
        let savedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let savedRecords = try XCTUnwrap(savedRoot["projects"] as? [[String: Any]])
        let savedPokemon = try XCTUnwrap(savedRecords.first { $0["id"] as? String == id.uuidString })
        XCTAssertEqual(savedPokemon["model"] as? String, LAAChatProject.Model.hydrogen.rawValue)
        XCTAssertEqual(savedPokemon["pendingModelOverride"] as? String, LAAChatProject.Model.hydrogen.rawValue)
        XCTAssertEqual(savedPokemon["pendingConversationIDOverride"] as? String, hydrogenID.uuidString)
        try withPending.complete(next, answer: "New answer", in: id)
        let completed = try XCTUnwrap(LAAChatProjectStore(fileURL: file).project(id))
        XCTAssertNil(completed.pending)
        XCTAssertEqual(completed.history.compactMap(\.model), [.deepSeek, .deepSeek, .hydrogen])
    }

    func testBothBuiltInProjectsCompleteOnTheHydrogenRoute() async throws {
        let fixture = Runtime()
        let pin = LAAChatProjectRoute(model: "gemini-4-hydrogen", provider: "laa-agy", effort: "low")
        let table = try XCTUnwrap(LAAChatPokemon.bundled)
        for project in LAAChatProjectStore.seeds {
            let question = LAAChatProject.Message(role: .user, text: project.kind == .pokemon ? "ピカチュウ" : "2+2?")
            let reference: String?
            if project.kind == .pokemon {
                guard case .reference(let answer) = table.guidance(question.text, route: .init(context: project.context)) else {
                    return XCTFail("Expected a deterministic Pokémon reference")
                }
                reference = answer
            } else { reference = nil }
            let result = try await LAAChatProjectRunner.run(runtime: fixture, project: project, question: question,
                                                            referenceAnswer: reference)
            XCTAssertEqual(result, reference ?? "first second")
            XCTAssertEqual(fixture.created.last?.route, pin)
            XCTAssertEqual(fixture.submitted.last?.route, pin)
            XCTAssertEqual(fixture.created.last?.conversationID, project.conversationID(for: .hydrogen))
            XCTAssertEqual(fixture.submitted.last?.conversationID, fixture.created.last?.conversationID)
        }
        XCTAssertEqual(Set(fixture.created.map(\.conversationID)).count, 2)
    }

    func testMigrationPreservesUnknownPinAndFutureArchive() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "project-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let legacy = """
        {"projects":[{"id":"0198828b-238f-7294-a0a6-5b65830e1602","name":"Former","model":"unlisted-model"}]}
        """
        try Data(legacy.utf8).write(to: file)
        let restored = LAAChatProjectStore(fileURL: file)
        XCTAssertEqual(restored.projects.first?.model.rawValue, "unlisted-model")
        XCTAssertEqual(restored.projects.first?.kind, .general)
        XCTAssertEqual(restored.projects.first?.history, [])
        XCTAssertThrowsError(try LAAChatProjectRoute(try XCTUnwrap(restored.projects.first?.model))) {
            XCTAssertEqual($0 as? LAAChatProjectFailure, .init(.modelUnavailable))
        }
        let future = Data(#"{"schema":5,"projects":[]}"#.utf8)
        try future.write(to: file)
        let readOnly = LAAChatProjectStore(fileURL: file)
        XCTAssertTrue(readOnly.unavailable)
        XCTAssertThrowsError(try readOnly.create(name: "no", context: "", model: .hydrogen))
        XCTAssertEqual(try Data(contentsOf: file), future)
    }

    func testPinsAndExactProjectOnlyPrompt() async throws {
        for model in LAAChatProject.Model.choices {
            let fixture = Runtime()
            let history: [LAAChatProject.Message] = [.init(role: .user, text: "old"), .init(role: .assistant, text: "answer")]
            let project = LAAChatProject(name: "Project", context: "# Exactly this preset", model: model, history: history)
            var updates: [String] = []
            let result = try await LAAChatProjectRunner.run(runtime: fixture, project: project,
                                                            question: .init(role: .user, text: "new")) { updates.append($0) }
            XCTAssertEqual(result, "first second")
            XCTAssertEqual(updates, ["first", "first second"])
            let create = try XCTUnwrap(fixture.created.first)
            XCTAssertEqual(create.route.model, model.rawValue)
            XCTAssertEqual(create.route.provider, model.provider)
            XCTAssertEqual(create.route.effort, model.effort)
            XCTAssertEqual(create.conversationID, project.id)
            XCTAssertTrue(create.hidden)
            let submit = try XCTUnwrap(fixture.submitted.first)
            XCTAssertEqual(submit.system, project.context)
            XCTAssertEqual(submit.history, history)
            XCTAssertEqual(submit.text, "new")
            for contamination in ["SOUL", "Monet", "tools", "tool_catalog", "employee"] {
                XCTAssertFalse(submit.system.localizedCaseInsensitiveContains(contamination))
            }
        }
    }

    func testQuotaRetryAndNoSubstitution() async throws {
        let fixture = Runtime()
        let project = LAAChatProject(name: "P", context: "", model: .hydrogen)
        let retry = Date(timeIntervalSince1970: 1_798_000_000)
        fixture.events = [.accepted, .failed(.init(.quotaExhausted, retryAt: retry))]
        do {
            _ = try await LAAChatProjectRunner.run(runtime: fixture, project: project, question: .init(role: .user, text: "question"))
            XCTFail("Quota failure was discarded")
        } catch { XCTAssertEqual(error as? LAAChatProjectFailure, .init(.quotaExhausted, retryAt: retry)) }
        XCTAssertEqual(fixture.submitted.count, 1)
        fixture.events = [.accepted, .started(try LAAChatProjectRoute(.deepSeek)), .text("other model")]
        do {
            _ = try await LAAChatProjectRunner.run(runtime: fixture, project: project, question: .init(role: .user, text: "question")) { _ in XCTFail("Wrong model became visible") }
            XCTFail("Replacement was accepted")
        } catch { XCTAssertEqual(error as? LAAChatProjectFailure, .init(.modelUnavailable)) }
        XCTAssertEqual(fixture.submitted.map(\.route.provider), ["laa-agy", "laa-agy"])
    }

    func testLookupNormalizesLanguageAndFormsWithoutGuessing() throws {
        let table = try XCTUnwrap(LAAChatPokemon.bundled)
        XCTAssertEqual(table.count, 1_579)
        XCTAssertEqual(table.auditCount, 10)
        XCTAssertGreaterThan(table.estimableFormCount, 1_300)
        for name in ["ピカチュウ", "ぴかちゅう", "Pikachu", "皮卡丘", "Ｐｉｋａｃｈｕ"] {
            guard case .exact(let row) = table.match(name) else { return XCTFail("Missed \(name)") }
            XCTAssertEqual(row.national_dex_id, 25)
        }
        for name in ["アローラナッシー", "ナッシー（アローラのすがた）", "Alolan Exeggutor"] {
            guard case .exact(let row) = table.match(name) else { return XCTFail("Missed \(name)") }
            XCTAssertEqual(row.form, "exeggutor-alola")
        }
        guard case .exact(let flower) = table.match("フラベベ（赤い花）") else { return XCTFail("Missing kanji form") }
        XCTAssertEqual(flower.national_dex_id, 669)
        guard case .ambiguous = table.match("ナッシー") else { return XCTFail("Ambiguous regional form guessed") }
        guard case .ambiguous = table.match("フラベベ") else { return XCTFail("Ambiguous colour guessed") }
        XCTAssertEqual(table.match("not-a-pokemon"), .unknown)
        XCTAssertEqual(LAAChatPokemon.Route(context: "route: sv-native\n\n# Preset"), .native)
        guard case .reference(let native) = table.guidance("ピカチュウ", route: .native) else { return XCTFail("Missing native rule") }
        XCTAssertFalse(native.contains("HOME"))
        XCTAssertTrue(native.contains("255"))
        for (name, expected) in [("Nidoran♀", 29), ("ニドラン♂", 32)] {
            guard case .exact(let row) = table.match(name) else { return XCTFail("Missing distinct name \(name)") }
            XCTAssertEqual(row.national_dex_id, expected)
        }
        guard case .ambiguous = table.match("Nidoran") else { return XCTFail("Missing gender question") }
    }

    func testPKFiveWorkedRowsDigitForDigit() throws {
        typealias E = LAAChatPokemon.Estimate
        let table = try XCTUnwrap(LAAChatPokemon.bundled)
        let samples: [(String, [String])] = [
            ("Pikachu", ["0.40", "0.196", "0.200", "0.600", "0.700", "0.23", "0.24", "0.57", "0.56"]),
            ("Alolan Exeggutor", ["10.90", "5.341", "5.450", "16.350", "21.800", "6.56", "6.57", "15.27", "15.26"]),
            ("フラベベ（赤い花）", ["0.10", "0.049", "0.050", "0.150", "0.175", "0.05", "0.06", "0.15", "0.14"]),
            ("Vaporeon", ["1.00", "0.490", "0.500", "1.500", "1.550", "0.59", "0.60", "1.41", "1.40"]),
            ("Dondozo", ["12.00", "5.880", "6.000", "18.000", "21.000", "7.23", "7.24", "16.81", "16.80"])
        ]
        for (name, numbers) in samples {
            guard case .exact(let row) = table.match(name), case .reference(let answer) = table.guidance(name, route: .go) else {
                return XCTFail("Missing audited row \(name)")
            }
            let estimate = try XCTUnwrap(row.estimate)
            let tags = try XCTUnwrap(estimate.tags)
            let actual = [E.metres(cm: estimate.baseCentimetres)] + [tags.xxsLow, tags.xxsHigh, tags.xxlLow, tags.xxlHigh].map(E.metres(mm:))
                + [estimate.miniAll, estimate.miniPossible, estimate.jumboAll, estimate.jumboPossible].map(E.metres(cm:))
            XCTAssertEqual(actual, numbers, name)
            for number in numbers { XCTAssertTrue(answer.contains(number), "\(name) is missing \(number)") }
            XCTAssertTrue(answer.contains("照合済み（GO設定と一致）"))
            XCTAssertTrue(answer.contains("XXS \(numbers[1])–\(numbers[2]) m（上端を除く）"))
            XCTAssertTrue(answer.contains("XXL \(numbers[3])–\(numbers[4]) m"))
        }
    }

    func testUnauditedOrdinaryAndRegionalFormsGetConditionalEstimatesWithoutTagRanges() throws {
        let table = try XCTUnwrap(LAAChatPokemon.bundled)
        for (name, base, mini, jumbo) in [("コイキング", "0.90", "0.54", "1.26"), ("Kantonian Exeggutor", "2.00", "1.21", "2.80")] {
            guard case .reference(let answer) = table.guidance(name, route: .go) else { return XCTFail("Missing conditional estimate \(name)") }
            let tags = try XCTUnwrap(answer.range(of: "高さタグ"))
            let estimates = try XCTUnwrap(answer.range(of: "表示身長の推定"))
            XCTAssertLessThan(tags.lowerBound, estimates.lowerBound)
            XCTAssertTrue(answer.contains("基準 \(base) m"))
            XCTAssertTrue(answer.contains("\(mini) m は一部のみ"))
            XCTAssertTrue(answer.contains("\(jumbo) m は一部のみ"))
            XCTAssertTrue(answer.contains("図鑑の高さから計算（GOの基準身長が図鑑と同じ前提・未照合）"))
            XCTAssertFalse(answer.contains("実値範囲"))
            XCTAssertTrue(answer.contains("XS・XLも対象"))
            XCTAssertTrue(answer.contains("重さのタグは別"))
            XCTAssertTrue(answer.contains(LAACopy.ChatProjects.pokemonCaveat))
        }
    }

    func testExceptionsDoNotBorrowOrdinaryHeightOrAssumeSVTransferability() throws {
        let table = try XCTUnwrap(LAAChatPokemon.bundled)
        let cases = [("Wailord", "判定対象になりません"), ("pumpkaboo-super", "判定対象になりません"),
                     ("gourgeist-small", "判定対象になりません"), ("Scatterbug", "通常の換算は使えません"),
                     ("Spewpa", "通常の換算は使えません"), ("vivillon-meadow", "通常の換算は使えません"),
                     ("Mega Charizard X", "特殊な姿"), ("groudon-primal", "特殊な姿"),
                     ("Pikachu Rock Star", "特殊な姿"), ("Kantonian Zorua", "通常の換算は使えません"),
                     ("ナッシー", "どの姿ですか"), ("not-a-pokemon", "どのポケモンですか")]
        for (name, reason) in cases {
            guard case .local(let answer) = table.guidance(name, route: .go) else { return XCTFail("Guessed at \(name)") }
            XCTAssertTrue(answer.contains(reason), "\(name): \(answer)")
            XCTAssertFalse(answer.contains("表示身長の推定"), name)
            XCTAssertTrue(answer.contains(LAACopy.ChatProjects.pokemonCaveat), name)
            if name == "Wailord" {
                XCTAssertTrue(answer.contains("照合済み（GO設定と一致）"))
                XCTAssertTrue(answer.contains("GOの高さタグの実値範囲"))
            } else {
                XCTAssertFalse(answer.contains("実値範囲"), name)
            }
        }
    }

    func testModelCannotChangeConditionalSizeAnswer() async throws {
        let project = try XCTUnwrap(LAAChatProjectStore.seeds.last)
        let table = try XCTUnwrap(LAAChatPokemon.bundled)
        guard case .reference(let reference) = table.guidance("Magikarp", route: .go) else { return XCTFail("No estimate") }
        let fixture = Runtime()
        var updates: [String] = []
        let result = try await LAAChatProjectRunner.run(runtime: fixture, project: project,
                                                        question: .init(role: .user, text: "Magikarp"),
                                                        referenceAnswer: reference) { updates.append($0) }
        XCTAssertEqual(result, reference)
        XCTAssertEqual(updates, [reference])
        XCTAssertTrue(fixture.submitted.first?.system.contains(reference) == true)
        XCTAssertFalse(fixture.submitted.first?.system.contains("Pikachu") == true)
    }

    func testMusicPlayingHasNoImplicitAudioOwnership() throws {
        let seam = AudioSession()
        let coordinator = VoiceAudioSessionCoordinator(session: seam)
        let app = AppState()
        app.wakeOtherAudioProbe = { true }
        for _ in ["cold launch", "foreground", "open chat", "receive reply"] {
            XCTAssertThrowsError(try coordinator.acquire(.wakeListening))
        }
        XCTAssertFalse(app.responseHapticsMayUseCoreHaptics)
        XCTAssertEqual(seam.positiveActivations, 0)
        XCTAssertTrue(seam.configurations.isEmpty)
        let explicit = try coordinator.acquire(.conversationCapture)
        XCTAssertEqual(seam.positiveActivations, 1)
        XCTAssertFalse(seam.configurations[0].contains(.mixWithOthers))
        coordinator.release(explicit)
    }

    func testWorkFollowUpPhaseMappingAndDelivery() throws {
        typealias R = LAAWorkMessageForm.Readiness
        func resolve(_ phase: String, decision: Bool = false, stopping: Bool = false, successor: Bool = false) -> R {
            .resolve(phase: phase, needsDecision: decision, stopPending: stopping, hasSuccessor: successor)
        }
        XCTAssertEqual(resolve("awaiting_decision"), .queue)
        XCTAssertEqual(resolve("running", decision: true), .queue)
        XCTAssertEqual(resolve("awaiting_review"), .send)
        XCTAssertEqual(resolve("running", stopping: true), .confirmStop)
        XCTAssertEqual(resolve("stop_unconfirmed"), .confirmStop)
        XCTAssertEqual(resolve("stopped"), .resume)
        XCTAssertEqual(resolve("stopped", successor: true), .successor)
        XCTAssertEqual(resolve("unknown"), .refresh)
        XCTAssertEqual(LAAWorkMessageForm.delivery(mode: R.queue.mode, queue: true), "queue")
        XCTAssertNil(LAAWorkMessageForm.delivery(mode: R.resume.mode, queue: false))
        XCTAssertFalse(R.confirmStop.canSend)
    }

    @MainActor private final class Runtime: LAAChatProjectRuntime {
        var created: [LAAChatProjectCreate] = []
        var submitted: [LAAChatProjectSubmit] = []
        var events: [LAAChatProjectEvent]?
        func create(_ request: LAAChatProjectCreate) async throws { created.append(request) }
        func replay(conversationID: UUID, turnID: UUID) async throws -> [LAAChatProjectEvent] { events ?? [] }
        func submit(_ request: LAAChatProjectSubmit) -> AsyncThrowingStream<LAAChatProjectEvent, Error> {
            submitted.append(request)
            return AsyncThrowingStream { sink in
                (events ?? [.accepted, .started(request.route), .text("first"), .text(" second"), .completed("first second")])
                    .forEach { sink.yield($0) }
                sink.finish()
            }
        }
    }

    @MainActor private final class AudioSession: VoiceAudioSessionControlling {
        let isOtherAudioPlaying = true
        var configurations: [AVAudioSession.CategoryOptions] = []
        var positiveActivations = 0
        func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
            configurations.append(options)
        }
        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
            if active { positiveActivations += 1 }
        }
    }
}

@MainActor final class LAAChatProjectSnapshotTests: XCTestCase {
    func testPhoneAndDesktopProjectsSection() throws {
        try capture(width: 440, height: 956, name: "chat-projects-440x956") { list(desktop: false) }
        try capture(width: 1280, height: 800, name: "chat-projects-1280x800") { list(desktop: true) }
    }

    func testPokemonAuditedAndConditionalReplySnapshots() throws {
        let table = try XCTUnwrap(LAAChatPokemon.bundled)
        for (query, name, width, height) in [("ピカチュウ", "pokemon-audited-440x956", 440, 956),
                                            ("コイキング", "pokemon-conditional-1280x800", 1280, 800)] {
            guard case .reference(let answer) = table.guidance(query, route: .go) else { return XCTFail("Missing \(query)") }
            let store = LAAChatProjectStore(fileURL: nil)
            let id = LAAChatProjectStore.pokemonID
            try store.complete(.init(role: .user, text: query), answer: answer, in: id, localOnly: true)
            try capture(width: width, height: height, name: name) {
                LAAChatProjectDetail(store: store, id: id, runtime: LAAChatProjectFixtureRuntime())
                    .environment(\.laaDesktop, width > 440)
            }
        }
    }

    @ViewBuilder private func list(desktop: Bool) -> some View {
        let store = LAAChatProjectStore(fileURL: nil)
        let list = LAAChatsContent(snapshot: .init(people: [], rooms: [], groupsState: .ready,
                                                  canCreateChat: false, canCreateGroup: false),
                                   settingsAvailable: false, selection: desktop ? .init() : nil,
                                   openPerson: { _ in }, openRoom: { _ in }, newChat: {}, newGroup: {},
                                   openSettings: {}, retry: {}, searchChanged: {}, publishesMacCommands: false,
                                   projects: store.projects, openProject: { _ in }, newProject: {})
        if desktop {
            LAAMacListDetail {
                list.environment(\.laaDesktop, true)
            } detail: {
                LAAColor.background
            }
        } else { list }
    }

    private func capture<V: View>(width: Int, height: Int, name: String, @ViewBuilder view: () -> V) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.userInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: NavigationStack { view() })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        XCTAssertEqual(image.cgImage?.width, width)
        XCTAssertEqual(image.cgImage?.height, height)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
