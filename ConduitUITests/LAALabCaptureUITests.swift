#if LAA_BUILD && os(iOS) && !targetEnvironment(macCatalyst)
import XCTest

/// Opt-in only; capture.py supplies the selected IDs, fixture ports and expected traits.
final class LAALabCaptureUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var selected = Set<String>()
    private var captured = Set<String>()
    private let project = "work.project.proj_laa_fixture"
    private let requirement = "laa.work.project.requirement.title.req_capture_1"
    private let run = "work.session.ses_5555555555555555"
    private let waiting = "work.session.ses_2222222222222222"
    private let history = "work.session.ses_3333333333333333"
    private let decision = "work.decision.dec_0000000000000a01"
    private let task = "work.task.title.7a1c3d5e-2222-4a2b-9c3d-000000000100"
    private let studio = "laa.studio.work.70175325-5cf4-421f-8a6f-95beae8fca92"

    func testCapture() throws {
        guard let raw = env["LAA_LAB_SCREENS"], let traits = env["LAA_LAB_TRAITS"],
              let port = env["LAA_LAB_PORT"], UInt16(port) != nil else {
            throw XCTSkip("Run via scripts/laa/lab/capture.py with synthetic fixtures")
        }
        continueAfterFailure = false
        selected = Set(raw.split(separator: ",").map(String.init))
        var observed: String?
        func batch(_ ids: [String], tab: String, _ flags: [String] = [],
                   portName: String = "LAA_LAB_PORT", body: (XCUIApplication) -> Void) {
            guard ids.contains(where: selected.contains) else { return }
            let app = XCUIApplication()
            app.launchArguments = ["-LAA_LAB_CAPTURE", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                                   "-LAA_UI_TEST_WORK_FIXTURE_PORT", env[portName]!,
                                   "-LAA_UI_TEST_CLEAR_WORK_STORE", "-laa-tab", tab,
                                   "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://lab-capture.invalid",
                                   "-conduit.themePreference", "system",
                                   "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"] + flags
            if env["LAA_LAB_LONG_JAPANESE"] == "1" { app.launchArguments += ["-LAA_LAB_LONG_JAPANESE"] }
            app.launchEnvironment["CONDUIT_UITEST"] = "1"
            // The lab network policy only lets a declared loopback origin through.
            app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:\(env[portName]!)"
            app.launch()
            defer { app.terminate() }
            let probe = wait("laa.lab.capture.traits", app)
            let actual = probe.label
            XCTAssertEqual(actual, traits, "Effective traits on \(tab) / \(flags)")
            if observed == nil { observed = actual }
            body(app)
        }

        batch(["chat-staff"], tab: "chats", ["-LAA_UI_TEST_CHATS"]) { app in
            shot("chat-staff", after: "laa.chats.person.laa-monet", app)
        }
        batch(["chat-thread", "chat-composer"], tab: "chats", background("chat", "rich")) { app in
            wait("fixture.capture.ready", app)
            wait("chat.transcript", app)
            shot("chat-thread", after: "chat.message.assistant", app)
            if selected.contains("chat-composer") {
                let field = app.textViews.matching(identifier: "composer.field").firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 15))
                field.tap()
                let draft = "Fixture draft — please review the next steps."
                field.typeText(draft)
                XCTAssertEqual(field.value as? String, draft)
                shot("chat-composer", after: "composer.field", app)
            }
        }
        batch(["chat-group"], tab: "chats", background("group", "rich")) { app in
            wait("fixture.capture.ready", app)
            shot("chat-group", after: "room.composer.field", app)
        }
        batch(["chat-empty"], tab: "chats", background("chat", "empty")) { app in
            wait("fixture.capture.ready", app)
            XCTAssertFalse(element("chat.message.assistant", app).exists)
            shot("chat-empty", after: "composer.field", app)
        }

        batch(["work-projects", "work-requirements", "work-sessions", "work-session-history", "work-session-running",
               "work-session-waiting", "work-decisions", "work-decision-detail", "work-tasks", "work-task-detail", "work-routines",
               "work-campaigns", "usage", "usage-capacity"], tab: "work") { app in
            let row = wait(project, app)
            if env["LAA_LAB_LONG_JAPANESE"] == "1" {
                XCTAssertTrue((row.label + app.debugDescription).contains("長い日本語の名前"), "Long fixture is not in the accessibility tree")
            }
            shot("work-projects", after: project, app)
            if selected.contains("work-requirements") {
                // The swipe row sits inside a context-menu host at the same
                // identifier. Its progress line gives a point inside the row
                // even when the host has no XCTest hit point.
                if let row = hitTarget(project, app) { row.tap() }
                else { tapFrame("laa.work.project.progress.proj_laa_fixture", app) }
                shot("work-requirements", after: requirement, app)
                back(to: "work.section.projects", app)
            }
            if needs("work-sessions", "work-session-history", "work-session-running", "work-session-waiting") {
                segment("sessions", app)
                wait(run, app)
                wait(waiting, app)
                shot("work-sessions", after: "work.sessions", app)
                for (id, row, ready) in [("work-session-history", history, "work.session.history.ready"),
                                        ("work-session-running", run, "work.session.progress.thinking"),
                                        ("work-session-waiting", waiting, "work.session.decision.note.0")] where selected.contains(id) {
                    // Capture the detail through the app's real session URL.
                    // This does not depend on whether the preceding list row
                    // has an on-screen hit point at this Dynamic Type size.
                    let session = row.dropFirst("work.session.".count)
                    app.open(URL(string: "laa://work/sessions/\(session)")!)
                    shot(id, after: ready, app)
                    back(to: "work.section.sessions", app)
                }
            }
            if needs("work-decisions", "work-decision-detail") {
                segment("decisions", app)
                shot("work-decisions", after: decision, app)
                if selected.contains("work-decision-detail") {
                    reveal(decision, app)
                    tap(decision, app)
                    shot("work-decision-detail", after: "work.decision.option.0", app)
                    tap("work.decision.close", app)
                }
            }
            if selected.contains("work-campaigns") {
                segment("campaigns", app)
                shot("work-campaigns", after: "work.campaigns", app)
            }
            if needs("work-tasks", "work-task-detail") {
                segment("tasks", app)
                let filter = wait("work.tasks.quick", app)
                let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    filter.label.contains("28件")
                }, object: filter)
                XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed, "Fixture task count did not load")
                shot("work-tasks", after: "work.tasks.list", app)
                if selected.contains("work-task-detail") {
                    // This row can fall outside the materialized list at
                    // larger text sizes. Find it through the real search UI.
                    let search = wait("laa.work.search", app)
                    search.tap()
                    search.typeText("T30")
                    tap(task, app)
                    shot("work-task-detail", after: "work.task.detail.title", app)
                    tap("work.task.detail.close", app)
                }
            }
            if selected.contains("work-routines") {
                segment("routines", app)
                shot("work-routines", after: "work.routines.tree", app)
            }
            if needs("usage", "usage-capacity") {
                tap("work.usage", app)
                let updated = wait("laa.usage.updated", app)
                // Capacity is below the initial viewport on the phone. First
                // prove that the usage fetch finished without waiting on it.
                let fetched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    guard let value = updated.value as? String else { return false }
                    return value != "未取得" && !value.isEmpty
                }, object: updated)
                XCTAssertEqual(XCTWaiter.wait(for: [fetched], timeout: 15), .completed)
                shot("usage", after: "laa.usage.updated", app)
                if selected.contains("usage-capacity") {
                    let memory = "laa.capacity.capacity.mac-mini.memory"
                    reveal(memory, app)
                    shot("usage-capacity", after: memory, app)
                }
            }
        }
        batch(["settings"], tab: "work") { app in
            tap("laa.settings.open", app)
            shot("settings", after: "settings.chat", app)
        }
        for (mode, expected) in [("empty", "laa.lab.empty"), ("loading", "laa.lab.loading"),
                                 ("error", "laa.today.error")] {
            let id = "today-\(mode)"
            batch([id], tab: "today", portName: "LAA_LAB_PORT_" + mode.uppercased()) { app in
                shot(id, after: expected, app)
            }
        }
        batch(["today", "today-event"], tab: "today") { app in
            let row = "laa.calendar.event.fixture-event-1"
            shot("today", after: row, app)
            if selected.contains("today-event") {
                reveal(row, app)
                tap(row, app)
                shot("today-event", after: "laa.calendar.detail.title", app)
            }
        }
        batch(["doc", "doc-note"], tab: "brain", ["-laa-brain-fixture", "normal"]) { app in
            shot("doc", after: "laa.brain.folder.Company", app)
            if selected.contains("doc-note") {
                tap("laa.brain.folder.Company", app)
                let note = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "Start")).firstMatch
                XCTAssertTrue(note.waitForExistence(timeout: 15)); note.tap()
                shot("doc-note", after: "laa.brain.back", app)
            }
        }
        batch(["doc-error"], tab: "brain", ["-laa-brain-fixture", "offline"]) { app in
            shot("doc-error", after: "laa.brain.readError", app)
        }
        batch(["studio", "studio-work", "drive"], tab: "studio") { app in
            shot("studio", after: "laa.studio.menu", app)
            if selected.contains("drive") {
                tap("studio.drive", app)
                shot("drive", after: "laa.drive.browser.item.studio-reference", app)
                if selected.contains("studio-work") { tap("studio.section.studio", app) }
            }
            if selected.contains("studio-work") {
                reveal(studio, app)
                tap(studio, app)
                shot("studio-work", after: "laa.studio.gallery", app)
            }
        }

        XCTAssertEqual(captured, selected, "Missing capture IDs: \(selected.subtracting(captured).sorted())")
        let proof = XCTAttachment(string: observed ?? "missing")
        proof.name = "lab-traits"
        proof.lifetime = .keepAlways
        add(proof)
    }

    private func background(_ surface: String, _ state: String) -> [String] {
        ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", state, "-LAA_CAPTURE_SURFACE", surface]
    }

    private func needs(_ ids: String...) -> Bool { ids.contains(where: selected.contains) }

    private func query(_ id: String, _ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id))
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { query(id, app).firstMatch }

    private func hitTarget(_ id: String, _ app: XCUIApplication) -> XCUIElement? {
        query(id, app).allElementsBoundByIndex.first { $0.isHittable }
    }

    @discardableResult private func wait(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let item = element(id, app)
        if !item.waitForExistence(timeout: 15) {
            // Only this synthetic app instance; keep the tree in the text
            // log after the runner removes the failed xcresult bundle.
            print("LAA_LAB_MISSING_AX \(id)\n\(app.debugDescription)")
            XCTFail("Missing AX identifier: \(id)")
        }
        return item
    }

    private func tap(_ id: String, _ app: XCUIApplication) {
        wait(id, app)
        guard let item = hitTarget(id, app) else { return XCTFail("No hit point for \(id)") }
        item.tap()
    }

    private func tapFrame(_ id: String, _ app: XCUIApplication) {
        let frame = wait(id, app).frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard !frame.isEmpty, app.frame.contains(point) else { return XCTFail("No visible row frame for \(id)") }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
    }

    private func swipe(_ app: XCUIApplication, from: CGVector, to: CGVector) {
        app.coordinate(withNormalizedOffset: from).press(forDuration: 0.03,
            thenDragTo: app.coordinate(withNormalizedOffset: to), withVelocity: XCUIGestureVelocity(550), thenHoldForDuration: 0)
    }

    private func back(to id: String, _ app: XCUIApplication) {
        swipe(app, from: CGVector(dx: 0.006, dy: 0.48), to: CGVector(dx: 0.86, dy: 0.48))
        wait(id, app)
    }

    private func reveal(_ id: String, _ app: XCUIApplication) {
        let item = element(id, app)
        let viewport = app.frame
        let top = viewport.minY + 116, bottom = viewport.maxY - 100
        for attempt in 0..<12 {
            let frame = item.exists ? item.frame : .zero
            if !frame.isEmpty, item.isHittable, (top..<bottom).contains(frame.midY) { return }
            // Returning from a detail preserves the list's earlier position.
            // An AX row above the viewport must be brought down, not swiped
            // farther away. If the lazy row has no frame, scan both ways.
            let goBack = frame.isEmpty ? attempt >= 6 : frame.midY < top
            let upper = CGVector(dx: 0.65, dy: 0.43), lower = CGVector(dx: 0.65, dy: 0.73)
            swipe(app, from: goBack ? upper : lower, to: goBack ? lower : upper)
        }
    }

    private func segment(_ name: String, _ app: XCUIApplication) {
        let row = wait("work.segment", app)
        let button = element("work.section.\(name)", app)
        for _ in 0..<5 {
            if button.exists && button.isHittable && button.frame.midX > 28 && button.frame.midX < app.frame.width - 28 { break }
            let y = row.frame.midY / app.frame.height
            swipe(app, from: CGVector(dx: 0.85, dy: y), to: CGVector(dx: 0.25, dy: y))
        }
        tap("work.section.\(name)", app)
    }

    private func shot(_ id: String, after ready: String, _ app: XCUIApplication) {
        guard selected.contains(id) else { return }
        wait(ready, app)
        XCTAssertTrue(captured.insert(id).inserted, "Duplicate shot \(id)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "lab-\(id)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
