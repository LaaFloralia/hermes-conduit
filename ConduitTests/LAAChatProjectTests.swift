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
        XCTAssertEqual(store.projects.map(\.model), [.hydrogen, .deepSeek])
        XCTAssertEqual(store.projects.map(\.name), ["日常質問", "ポケモンサイズ証判定"])
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

    func testMigrationPreservesUnknownPinAndFutureArchive() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "project-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let legacy = """
        {"projects":[{"id":"0198828b-238f-7294-a0a6-5b65830e1601","name":"Former","model":"unlisted-model"}]}
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
        guard case .verified(let answer) = table.guidance("ピカチュウ", route: .go) else { return XCTFail("Missing audited row") }
        XCTAssertTrue(answer.contains("メートル表示だけでは証を保証しません"))
        XCTAssertTrue(answer.contains("Scale 255"))
        XCTAssertEqual(LAAChatPokemon.Route(context: "route: sv-native\n\n# Preset"), .native)
        guard case .local = table.guidance("コイキング", route: .go) else { return XCTFail("Unaudited metres shown") }
        guard case .verified(let native) = table.guidance("ピカチュウ", route: .native) else { return XCTFail("Missing native rule") }
        XCTAssertFalse(native.contains("HOME"))
        XCTAssertTrue(native.contains("255"))
    }

    func testModelCannotChangeAuditedSizeAnswer() async throws {
        let project = try XCTUnwrap(LAAChatProjectStore.seeds.last)
        let table = try XCTUnwrap(LAAChatPokemon.bundled)
        guard case .verified(let verified) = table.guidance("Bulbasaur", route: .go) else { return XCTFail("No audited line") }
        let fixture = Runtime()
        var updates: [String] = []
        let result = try await LAAChatProjectRunner.run(runtime: fixture, project: project,
                                                        question: .init(role: .user, text: "Bulbasaur"),
                                                        verifiedAnswer: verified) { updates.append($0) }
        XCTAssertEqual(result, verified)
        XCTAssertEqual(updates, [verified])
        XCTAssertTrue(fixture.submitted.first?.system.contains(verified) == true)
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
        try capture(width: 440, height: 956, desktop: false)
        try capture(width: 1280, height: 800, desktop: true)
    }

    private func capture(width: Int, height: Int, desktop: Bool) throws {
        let store = LAAChatProjectStore(fileURL: nil)
        let list = LAAChatsContent(snapshot: .init(people: [], rooms: [], groupsState: .ready,
                                                  canCreateChat: false, canCreateGroup: false),
                                   settingsAvailable: false, selection: desktop ? .init() : nil,
                                   openPerson: { _ in }, openRoom: { _ in }, newChat: {}, newGroup: {},
                                   openSettings: {}, retry: {}, searchChanged: {}, publishesMacCommands: false,
                                   projects: store.projects, openProject: { _ in }, newProject: {})
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.userInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            if desktop {
                HStack(spacing: 0) {
                    list.frame(width: LAADesktopMetrics.listIdealWidth)
                    Divider()
                    LAAColor.background
                }
            } else { list }
        })
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
        attachment.name = "chat-projects-\(width)x\(height)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
