#if LAA_BUILD
import XCTest

final class LAAWorkUITests: XCTestCase {
    func testKeychainFailureOffersRetryInsteadOfNewPairing() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "work", "-LAA_UI_TEST_KEYCHAIN_ERROR"]
        app.launchInLab()
        XCTAssertTrue(app.staticTexts["接続情報を読み取れません"].waitForExistence(timeout: 30))
        let retry = app.buttons["work.retry-credentials"]
        XCTAssertTrue(retry.exists)
        XCTAssertFalse(app.buttons["work.connect"].exists)
        retry.tap()
        XCTAssertTrue(retry.exists)
        XCTAssertFalse(app.buttons["work.connect"].exists)
    }

    private func launchWork() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "work"]
        if let address = ProcessInfo.processInfo.environment["LAA_BRIDGE_DEFAULT_ADDRESS"] {
            app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = address
        }
        if let appearance = ProcessInfo.processInfo.environment["LAA_WORK_LIVE_APPEARANCE"],
           ["light", "dark"].contains(appearance) {
            app.launchArguments += ["-conduit.themePreference", appearance]
        }
        app.launchInLab()
        XCTAssertTrue(app.buttons["work.section.tasks"].waitForExistence(timeout: 30))
        return app
    }

    private func pairedLaneWork() throws -> XCUIApplication {
        continueAfterFailure = false
        let app = WorkLaneUI.launch()
        try WorkLaneUI.pair(app)
        return app
    }

    private func openLaneProject(_ name: String, instructions: String? = nil) throws -> (XCUIApplication, String) {
        var setup = ["name": name]
        setup["instructions"] = instructions
        let id = try XCTUnwrap(WorkLaneUI.setup("project", setup)["id"] as? String)
        let app = try pairedLaneWork()
        let row = app.staticTexts[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20)); row.tap()
        return (app, id)
    }

    private func projectEditor(in app: XCUIApplication) -> XCUIElement {
        let edit = app.buttons["laa.work.project.editInstructions"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        if !edit.isHittable { app.swipeUp() }
        edit.tap()
        let field = app.textViews["work.project.instructions"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        return field
    }

    private func saveProject(in app: XCUIApplication) {
        let save = app.buttons["保存"].firstMatch
        if !save.isHittable { app.swipeUp() }
        XCTAssertTrue(waitUntilReady(save, timeout: 15))
        save.tap()
    }

    private func laneProjectConflict(name: String) throws {
        let (app, projectID) = try openLaneProject(name)
        let field = projectEditor(in: app)
        field.tap(); field.typeText("Lab UI revision")
        _ = try WorkLaneUI.setup("revise-project", ["id": projectID])
        saveProject(in: app)
        XCTAssertTrue(app.staticTexts["Server revision"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Lab UI revision"].firstMatch.exists)
        let adopt = app.buttons["現在の内容を使う"]
        if !adopt.isHittable { app.swipeUp() }
        XCTAssertTrue(waitUntilReady(adopt, timeout: 15)); adopt.tap()
        XCTAssertEqual(field.value as? String, "Server revision")
    }

    private func startLaneConversation(_ prompt: String, project name: String) throws -> XCUIApplication {
        let projectID = try XCTUnwrap(WorkLaneUI.setup("project", ["name": name])["id"] as? String)
        let app = try pairedLaneWork()
        WorkLaneUI.composer(app)
        // The new-session sheet's harness comes from the lane's own options.
        let harness = app.descendants(matching: .any)["work.launch.harness"].firstMatch
        XCTAssertTrue(harness.waitForExistence(timeout: 10))
        XCTAssertEqual(harness.value as? String, "Echo")
        let picker = app.descendants(matching: .any)["work.launch.project"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10)); picker.tap()
        let project = app.buttons["work.launch.project.\(projectID)"]
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        let field = app.textViews["work.launch.composer.field"]
        field.tap(); field.typeText(prompt)
        let send = app.buttons["work.launch.composer.send"]
        XCTAssertTrue(waitUntilReady(send, timeout: 15)); send.tap()
        XCTAssertTrue(transcript("Lab Echo: \(prompt)", in: app).waitForExistence(timeout: 40))
        return app
    }

    private func laneFollowUp(relaunch: Bool) throws {
        let name = relaunch ? "Lab follow-up readback" : "Lab follow-up"
        let projectName = relaunch ? "Lab readback project" : "Lab follow-up project"
        let app = try startLaneConversation(name, project: projectName)
        let field = app.textViews["work.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20)); field.tap(); field.typeText("Lab next turn")
        let send = app.buttons["work.composer.send"]
        XCTAssertTrue(waitUntilReady(send, timeout: 20)); send.tap()
        let echo = transcript("Lab Echo: Lab next turn", in: app)
        XCTAssertTrue(echo.waitForExistence(timeout: 40))
        if relaunch {
            app.terminate(); app.launchInLab()
            // The global Sessions view deliberately hides a non-LAA project
            // whose cwd isn't /Users/laa. Reopen from its actual project.
            let projects = app.buttons["work.section.projects"]
            XCTAssertTrue(projects.waitForExistence(timeout: 15)); projects.tap()
            let project = app.staticTexts[projectName].firstMatch
            XCTAssertTrue(project.waitForExistence(timeout: 20)); project.tap()
            XCTAssertFalse(app.buttons["work.connect"].exists)
            let row = app.staticTexts[name].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            XCTAssertTrue(reveal(row, in: app)); row.tap()
            XCTAssertTrue(echo.waitForExistence(timeout: 20))
        }
    }

    private func transcript(_ text: String, in app: XCUIApplication) -> XCUIElement {
        // Work markdown is selectable and exposes its text as a TextView.
        app.textViews.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    private func waitUntilReady(_ element: XCUIElement, timeout: TimeInterval = 60) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<7 {
            if element.isHittable { return true }
            app.scrollViews.firstMatch.swipeUp()
        }
        return element.isHittable
    }

    private func openSession(_ app: XCUIApplication, id: String) -> Bool {
        guard waitUntilReady(app.buttons["work.create"]) else { return false }
        let row = app.staticTexts["work.session.\(id)"].firstMatch
        guard row.waitForExistence(timeout: 30), reveal(row, in: app) else { return false }
        row.tap()
        return app.navigationBars.firstMatch.waitForExistence(timeout: 30)
    }

    private func openScratchSession(_ app: XCUIApplication) -> Bool {
        guard waitUntilReady(app.buttons["work.create"]) else { return false }
        let row: XCUIElement
        if let id = ProcessInfo.processInfo.environment["LAA_WORK_LIVE_SESSION_ID"], !id.isEmpty {
            row = app.staticTexts["work.session.\(id)"].firstMatch
        } else {
            row = app.staticTexts["LAA 14i validation"].firstMatch
        }
        guard row.waitForExistence(timeout: 30), reveal(row, in: app) else { return false }
        row.tap()
        return app.navigationBars["LAA 14i validation"].waitForExistence(timeout: 30)
    }

    private func openScratchProject(_ app: XCUIApplication) -> Bool {
        guard waitUntilReady(app.buttons["work.create"]) else { return false }
        app.buttons["work.section.projects"].tap()
        let row = app.staticTexts["LAA 14i Project Test 20261029"].firstMatch
        guard row.waitForExistence(timeout: 30), reveal(row, in: app) else { return false }
        row.tap()
        return app.navigationBars["Project"].waitForExistence(timeout: 30)
    }

    private func enterDedicatedAddress(_ address: XCUIElement) -> Bool {
        guard address.waitForExistence(timeout: 10) else { return false }
        if address.value as? String == "http://127.0.0.1:19414" { return true }
        for _ in 0..<4 {
            let existing = address.value as? String ?? ""
            if existing.isEmpty || existing == "Address" { break }
            address.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        let remaining = address.value as? String ?? ""
        guard remaining.isEmpty || remaining == "Address" else {
            print("Address characters remaining after clearing: \(remaining.count)")
            return false
        }
        address.typeText("http://127.0.0.1:19414")
        let entered = address.value as? String ?? ""
        guard entered == "http://127.0.0.1:19414" else {
            print("Entered address did not match; character count: \(entered.count)")
            return false
        }
        return true
    }

    func testDedicatedSimulatorAddressEntry() throws {
        if LabUI.active {
            continueAfterFailure = false
            let app = WorkLaneUI.launch()
            WorkLaneUI.openPairing(app)
            let address = app.textFields["laa.bridge.address"]
            XCTAssertTrue(address.waitForExistence(timeout: 10))
            let expected = try XCTUnwrap(LabUI.bridge)
            XCTAssertEqual(address.value as? String, expected)
            address.tap()
            address.typeText("7")
            XCTAssertEqual((address.value as? String)?.count, expected.count + 1)
            address.typeText(XCUIKeyboardKey.delete.rawValue)
            XCTAssertEqual(address.value as? String, expected)
            return
        }
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_ADDRESS"] == "1" else {
            throw XCTSkip("Explicit address-entry diagnostic is not enabled.")
        }
        let app = launchWork()
        let connect = app.buttons["work.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        connect.tap()
        XCTAssertTrue(enterDedicatedAddress(app.textFields["laa.bridge.address"]))
    }

    func testUnpairedWorkOffersPairing() {
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launchInLab()
        let connect = app.buttons["work.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 30))
        connect.tap()
        XCTAssertTrue(app.textFields["laa.bridge.address"].waitForExistence(timeout: 10))
    }

    func testWorkSegmentsAndRoutinePlaceholderWhenUnpaired() {
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launchInLab()
        XCTAssertTrue(app.buttons["work.section.tasks"].waitForExistence(timeout: 30))
        for name in ["sessions", "tasks", "routines"] {
            let segment = app.buttons["work.section.\(name)"]
            if !segment.isHittable { app.scrollViews["work.segment"].swipeLeft() }
            XCTAssertTrue(segment.exists)
            segment.tap()
            XCTAssertTrue(app.buttons["work.connect"].waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.buttons["work.usage"].exists)
    }

    func testOwnerTasksRequirePairingWithoutExposingLegacyLocalTasks() {
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launchInLab()
        XCTAssertTrue(app.buttons["work.section.tasks"].waitForExistence(timeout: 30))
        app.buttons["work.section.tasks"].tap()
        XCTAssertTrue(app.buttons["work.connect"].exists)
        XCTAssertFalse(app.buttons["work.linear.add"].isEnabled)
        XCTAssertFalse(app.buttons["work.ownerTasks.pending"].exists)
    }

    private func captureUnpairedDesign(_ appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-conduit.themePreference", appearance]
        app.launchInLab()
        XCTAssertTrue(app.buttons["work.connect"].waitForExistence(timeout: 30))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "work-tabs-\(appearance)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCaptureDesignUnpairedLight() { captureUnpairedDesign("light") }
    func testCaptureDesignUnpairedDark() { captureUnpairedDesign("dark") }

    // This helper is opt-in on a dedicated simulator. The one-time code is
    // pasted from its clipboard, so XCTest never receives it as typed text.
    func testPairDedicatedSimulator() throws {
        if LabUI.active {
            continueAfterFailure = false
            let app = WorkLaneUI.launch()
            try WorkLaneUI.pair(app)
            WorkLaneUI.sessions(app)
            return
        }
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_PAIR"] == "1" else {
            throw XCTSkip("Explicit live pairing is not enabled.")
        }
        let app = launchWork()
        let connect = app.buttons["work.connect"]
        guard connect.waitForExistence(timeout: 15) else {
            if waitUntilReady(app.buttons["work.create"]) {
                throw XCTSkip("The dedicated simulator is already paired.")
            }
            XCTFail("Neither the unpaired nor the paired Work screen appeared.")
            return
        }
        connect.tap()
        let address = app.textFields["laa.bridge.address"]
        guard enterDedicatedAddress(address) else {
            XCTFail("The dedicated simulator address was not entered exactly.")
            return
        }

        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        if let fixtureCode = ProcessInfo.processInfo.environment["LAA_WORK_FIXTURE_PAIR_CODE"] {
            // Only for a throwaway fixture Bridge; a real code is always pasted.
            code.tap()
            code.typeText(fixtureCode)
        } else {
            code.press(forDuration: 1)
            let paste = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Paste", "ペースト"])).firstMatch
            XCTAssertTrue(paste.waitForExistence(timeout: 5))
            paste.tap()
        }
        app.buttons["laa.bridge.pair"].tap()
        guard waitUntilReady(app.buttons["work.create"], timeout: 30) else {
            let errors = ["接続先はTailscaleのHTTPSアドレスで入力してください。",
                          "Macに届きません。TailscaleとMacの接続を確認してください。",
                          "安全な接続を確認できません。接続先と証明書を確認してください。",
                          "Macからの応答を読み取れませんでした。",
                          "接続情報を端末に保存または読み出しできませんでした。",
                          "認証できませんでした。コードの期限と入力を確認してください。"]
            let visible = errors.filter { app.staticTexts[$0].exists }
            XCTFail("Pairing did not complete. Visible error: \(visible.joined(separator: " / "))")
            return
        }
    }

    func testLiveBridgeFailureIsVisible() throws {
        try XCTSkipIf(LabUI.active, "Requires a scoped upstream failure or offline injection; the real lane Bridge is left healthy for other tests.")
        let mode = ProcessInfo.processInfo.environment["LAA_WORK_LIVE_FAILURE"]
        guard mode == "error" || mode == "offline" else {
            throw XCTSkip("Explicit live failure injection is not enabled.")
        }
        let app = launchWork()
        let expected = mode == "offline"
            ? "Macに届きません。TailscaleとMacの接続を確認してください。"
            : "Mac側のサービスを利用できません。"
        XCTAssertTrue(app.staticTexts["取得できませんでした"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts[expected].exists)
        XCTAssertFalse(app.buttons["work.create"].isEnabled)
    }

    func testLiveEmptySessionList() throws {
        if LabUI.active {
            continueAfterFailure = false
            XCTAssertEqual(try WorkLaneUI.setup("empty-sessions")["empty"] as? Bool, true)
            let app = try pairedLaneWork()
            WorkLaneUI.sessions(app)
            XCTAssertTrue(app.staticTexts["セッションはまだありません。"].waitForExistence(timeout: 20))
            return
        }
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_EMPTY"] == "1" else {
            throw XCTSkip("Explicit live empty-response injection is not enabled.")
        }
        let app = launchWork()
        XCTAssertTrue(app.staticTexts["セッションはまだありません。"].waitForExistence(timeout: 30))
    }

    func testCaptureLiveSessionList() throws {
        guard LabUI.active || ProcessInfo.processInfo.environment["LAA_WORK_LIVE_SCREENSHOT"] == "1" else {
            throw XCTSkip("Explicit live screenshots are not enabled.")
        }
        let app = try LabUI.active ? pairedLaneWork() : launchWork()
        if LabUI.active { WorkLaneUI.sessions(app) }
        XCTAssertTrue(waitUntilReady(app.buttons["work.create"], timeout: 30))
        if ProcessInfo.processInfo.environment["LAA_WORK_LIVE_EMPTY"] == "1" {
            XCTAssertTrue(app.staticTexts["セッションはまだありません。"].waitForExistence(timeout: 30))
        }
        let loading = app.progressIndicators["読み込み中"]
        if loading.exists {
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading)
            waitForExpectations(timeout: 30)
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "14i-work-sessions"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLiveWorkSectionsAndSessionEntry() throws {
        if LabUI.active {
            let app = try pairedLaneWork()
            WorkLaneUI.composer(app)
            XCTAssertTrue(app.navigationBars["新しいセッション"].exists)
            XCTAssertTrue(app.buttons["入力欄を広げる"].exists)
            app.buttons["閉じる"].tap()
            app.buttons["work.section.projects"].tap()
            let newProject = app.buttons["work.projects.new"]
            XCTAssertTrue(newProject.waitForExistence(timeout: 10)); newProject.tap()
            XCTAssertTrue(app.navigationBars["新しいプロジェクト"].waitForExistence(timeout: 10))
            return
        }
        let app = launchWork()
        if app.buttons["work.connect"].waitForExistence(timeout: 3) {
            throw XCTSkip("Pair the dedicated test simulator with the real Bridge before this flow.")
        }
        let add = app.buttons["work.create"]
        guard waitUntilReady(add) else { XCTFail("Session data did not finish loading."); return }
        add.tap(); app.buttons["work.sessions.new"].tap()
        XCTAssertTrue(app.navigationBars["新しいセッション"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["文字サイズ"].exists)
        XCTAssertTrue(app.buttons["入力欄を広げる"].exists)
        app.buttons["閉じる"].tap()
        app.buttons["work.section.projects"].tap()
        let addProject = app.buttons["work.projects.new"]
        XCTAssertTrue(addProject.waitForExistence(timeout: 10))
        addProject.tap()
        XCTAssertTrue(app.navigationBars["新しいプロジェクト"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["プロジェクト名"].exists)
        app.buttons["閉じる"].tap()
        app.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["Linearが現在のタスクの正本です。ここでは閲覧のみできます。"].waitForExistence(timeout: 30))
        app.buttons["Routines"].tap()
        XCTAssertTrue(app.staticTexts["準備中"].waitForExistence(timeout: 5))
    }

    // Separating workspace creation from session creation makes each external
    // write observable before the next one is attempted.
    func testLiveCreateScratchSession() throws {
        if LabUI.active {
            let app = try startLaneConversation("Lab UI session", project: "Lab session project")
            // The harness capsule names what the lane's session runs on: the
            // isolated engine's built-in Echo, read back from the daemon.
            let harness = app.descendants(matching: .any)["work.session.harness"].firstMatch
            XCTAssertTrue(harness.waitForExistence(timeout: 20))
            expectation(for: NSPredicate(format: "value == %@", "Echo"), evaluatedWith: harness)
            waitForExpectations(timeout: 20)
            let model = app.descendants(matching: .any)["work.session.model"].firstMatch
            XCTAssertTrue(model.exists)
            XCTAssertLessThanOrEqual(harness.frame.maxX, model.frame.minX + 1, "the harness leads the model")
            XCTAssertEqual(harness.frame.midY, model.frame.midY, accuracy: 2, "on the model's line")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "lane-session-harness"; shot.lifetime = .keepAlways; add(shot)
            return
        }
        let stage = ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"]
        guard stage == "session" || stage == "session-preflight" else {
            throw XCTSkip("Explicit scratch-session creation is not enabled.")
        }
        let app = launchWork()
        let add = app.buttons["work.create"]
        guard waitUntilReady(add) else { XCTFail("Session data did not finish loading."); return }
        add.tap(); app.buttons["work.sessions.new"].tap()
        let projectPicker = app.descendants(matching: .any)["work.launch.project"].firstMatch
        guard projectPicker.waitForExistence(timeout: 10) else { XCTFail("Project picker unavailable."); return }
        projectPicker.tap()
        let testProject = app.buttons["LAA 14i Project Test 20261029"]
        guard testProject.waitForExistence(timeout: 10) else { XCTFail("Scratch Project unavailable."); return }
        testProject.tap()
        XCTAssertTrue(app.descendants(matching: .any)["work.launch.model"].firstMatch.waitForExistence(timeout: 10))
        let prompt = app.textViews["work.launch.composer.field"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap()
        prompt.typeText("Reply exactly 14i-ready. Do not change files.")
        let start = app.buttons["work.launch.composer.send"]
        guard start.isEnabled else { XCTFail("Scratch-session start is not ready."); return }
        if stage == "session-preflight" { return }
        start.tap()
        XCTAssertTrue(app.staticTexts["Reply exactly 14i-ready.…"].waitForExistence(timeout: 120))
    }

    // Each opt-in mutation is isolated so an uncertain result is never retried
    // as a new write without first reconciling the Bridge state.
    func testLiveCreateScratchProject() throws {
        if LabUI.active {
            let app = try pairedLaneWork()
            let add = app.buttons["work.projects.new"]
            XCTAssertTrue(waitUntilReady(add, timeout: 15)); add.tap()
            let name = app.textFields["プロジェクト名"]
            XCTAssertTrue(name.waitForExistence(timeout: 15)); name.tap(); name.typeText("Lab UI project")
            saveProject(in: app)
            XCTAssertTrue(app.staticTexts["Lab UI project"].firstMatch.waitForExistence(timeout: 30))
            return
        }
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "project-create" else {
            throw XCTSkip("Explicit scratch-Project creation is not enabled.")
        }
        let app = launchWork()
        guard waitUntilReady(app.buttons["work.create"]) else { XCTFail("Work did not load."); return }
        app.buttons["work.section.projects"].tap()
        let add = app.buttons["work.projects.new"]
        guard waitUntilReady(add) else { XCTFail("Project creation unavailable."); return }
        add.tap()
        let name = app.textFields["プロジェクト名"]
        guard name.waitForExistence(timeout: 10), ["", "プロジェクト名"].contains(name.value as? String ?? "") else {
            XCTFail("The scratch Project name field was not empty."); return
        }
        name.tap()
        name.typeText("LAA 14i Project Test 20261029")
        guard name.value as? String == "LAA 14i Project Test 20261029" else { XCTFail("Wrong Project name."); return }
        let save = app.buttons["Save"]
        guard save.isEnabled else { XCTFail("Project creation is not ready."); return }
        save.tap()
        XCTAssertTrue(app.staticTexts["LAA 14i Project Test 20261029"].waitForExistence(timeout: 60))
    }

    func testLiveEditScratchProject() throws {
        if LabUI.active {
            let (app, _) = try openLaneProject("Lab edit project")
            let field = projectEditor(in: app)
            field.tap(); field.typeText("Lab shared instructions")
            saveProject(in: app)
            XCTAssertTrue(field.waitForNonExistence(timeout: 15))
            XCTAssertEqual(projectEditor(in: app).value as? String, "Lab shared instructions")
            return
        }
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "project-edit" else {
            throw XCTSkip("Explicit scratch-Project edit is not enabled.")
        }
        let app = launchWork()
        guard openScratchProject(app), app.staticTexts["共通指示はありません。"].waitForExistence(timeout: 30) else {
            XCTFail("The scratch Project or its empty instructions did not load."); return
        }
        app.buttons["Edit"].tap()
        let instructions = app.textViews["work.project.instructions"]
        guard instructions.waitForExistence(timeout: 10), (instructions.value as? String ?? "").isEmpty else {
            XCTFail("The scratch Project instructions were not empty."); return
        }
        instructions.tap()
        instructions.typeText("Reply only as asked. Do not modify files.")
        guard instructions.value as? String == "Reply only as asked. Do not modify files." else {
            XCTFail("The scratch instruction body did not match."); return
        }
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Reply only as asked. Do not modify files."].waitForExistence(timeout: 60))
    }

    func testLiveProjectRealConflict() throws {
        if LabUI.active { try laneProjectConflict(name: "Lab version conflict"); return }
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "project-stale" else {
            throw XCTSkip("Explicit scratch-Project conflict is not enabled.")
        }
        let app = launchWork()
        guard openScratchProject(app), app.staticTexts["Reply only as asked. Do not modify files."].waitForExistence(timeout: 30) else {
            XCTFail("The scratch Project instruction body did not load."); return
        }
        app.buttons["Edit"].tap()
        let instructions = app.textViews["work.project.instructions"]
        guard instructions.waitForExistence(timeout: 10) else { XCTFail("Instruction editor unavailable."); return }
        instructions.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.1)).tap()
        instructions.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Reply only as asked. Do not modify files.".count))
        guard (instructions.value as? String ?? "").isEmpty else { XCTFail("Could not clear test instructions."); return }
        instructions.typeText("My 14i revision")
        guard instructions.value as? String == "My 14i revision" else { XCTFail("The test edit did not match."); return }
        app.buttons["Save"].tap()
        guard app.staticTexts["現在の指示:"].waitForExistence(timeout: 30) else {
            XCTFail("The real Bridge conflict was not shown."); return
        }
        XCTAssertTrue(app.staticTexts["Reply only as asked. Do not modify files."].exists)
        XCTAssertTrue(app.staticTexts["My 14i revision"].exists)
        let adopt = app.buttons["現在の内容を使う"]
        guard adopt.isEnabled else { XCTFail("Conflict choice unavailable."); return }
        adopt.tap()
        XCTAssertEqual(instructions.value as? String, "Reply only as asked. Do not modify files.")
    }

    func testLiveScratchHistoryRecovery() throws {
        try XCTSkipIf(LabUI.active, "Requires cursor-gap, expiry or resync responses; the Echo lane does not inject these faults.")
        let stage = ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] ?? ""
        guard ["gap", "expired", "resync"].contains(stage) else { throw XCTSkip("History fault injection is not enabled.") }
        let app = launchWork()
        guard openScratchSession(app) else { XCTFail("Scratch session unavailable."); return }
        let notice = stage == "resync"
            ? "委譲先を観測できず再同期が必要です。詳細と成果物を読み直しています。"
            : "記録の取得位置が期限切れか、履歴に欠落しました。詳細と成果物を読み直しました。"
        XCTAssertTrue(app.staticTexts[notice].waitForExistence(timeout: 40))
        XCTAssertFalse(app.staticTexts["新着なし"].exists)
        XCTAssertTrue(app.staticTexts["最新の回答"].exists)
    }

    func testLiveScratchFollowUp() throws {
        if LabUI.active { try laneFollowUp(relaunch: false); return }
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "follow-up" else { throw XCTSkip("Follow-up is not enabled.") }
        let app = launchWork()
        guard openScratchSession(app), app.staticTexts["○ 確認待ち"].waitForExistence(timeout: 180) else {
            XCTFail("Scratch session did not reach review."); return
        }
        let field = app.textViews["work.composer.field"]
        guard reveal(field, in: app), (field.value as? String ?? "").isEmpty else { XCTFail("Follow-up draft unavailable or not empty."); return }
        field.tap()
        field.typeText("Reply exactly 14i-followup. Do not change files.")
        guard field.value as? String == "Reply exactly 14i-followup. Do not change files." else { XCTFail("Follow-up text did not match."); return }
        let send = app.buttons["work.composer.send"]
        guard send.isEnabled else { XCTFail("Follow-up is not ready."); return }
        send.tap()
        XCTAssertTrue(app.staticTexts["追加指示を送信"].waitForExistence(timeout: 180))
    }

    func testLiveScratchFollowUpReadback() throws {
        if LabUI.active { try laneFollowUp(relaunch: true); return }
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "follow-up-readback" else { throw XCTSkip("Follow-up readback is not enabled.") }
        let app = launchWork()
        guard openScratchSession(app) else { XCTFail("Scratch session unavailable."); return }
        XCTAssertTrue(app.staticTexts["追加指示を送信"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["最新の回答"].exists)
    }

    func testLiveScratchStop() throws {
        try XCTSkipIf(LabUI.active, "Legacy Stop from review was replaced by Interrupt during an active turn; the old Stop/Resume UI is gone.")
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "stop" else { throw XCTSkip("Stop is not enabled.") }
        let app = launchWork()
        guard openScratchSession(app), app.staticTexts["○ 確認待ち"].waitForExistence(timeout: 180) else {
            XCTFail("Scratch session did not reach review."); return
        }
        let stop = app.buttons["Stop"]
        guard reveal(stop, in: app), stop.isEnabled else { XCTFail("Stop unavailable."); return }
        stop.tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 90))
    }

    func testLiveScratchResume() throws {
        try XCTSkipIf(LabUI.active, "The current app explicitly does not offer resuming a stopped session.")
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "resume" else { throw XCTSkip("Resume is not enabled.") }
        let app = launchWork()
        guard openScratchSession(app) else { XCTFail("Scratch session unavailable."); return }
        let resume = app.buttons["Resume"]
        guard resume.waitForExistence(timeout: 30), reveal(resume, in: app) else { XCTFail("Confirmed stop unavailable."); return }
        resume.tap()
        let field = app.textViews["work.resume.composer.field"]
        guard field.waitForExistence(timeout: 10), (field.value as? String ?? "").isEmpty else { XCTFail("Continuation draft unavailable or not empty."); return }
        field.tap()
        field.typeText("Reply exactly 14i-resumed. Do not change files.")
        guard field.value as? String == "Reply exactly 14i-resumed. Do not change files." else { XCTFail("Continuation text did not match."); return }
        let send = app.buttons["work.resume.composer.send"]
        guard send.isEnabled else { XCTFail("Resume is not ready."); return }
        send.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Successor Session:")).firstMatch.waitForExistence(timeout: 120))
    }

    func testLiveScratchStopSuccessor() throws {
        try XCTSkipIf(LabUI.active, "Depends on the retired Resume flow to create a successor and the retired Stop from review.")
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "stop-successor" else { throw XCTSkip("Successor cleanup is not enabled.") }
        let app = launchWork()
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_SESSION_ID"]?.isEmpty == false,
              openScratchSession(app),
              app.staticTexts["○ 確認待ち"].waitForExistence(timeout: 180) else {
            XCTFail("The designated scratch successor did not reach review."); return
        }
        let stop = app.buttons["Stop"]
        guard reveal(stop, in: app), stop.isEnabled else { XCTFail("Successor stop unavailable."); return }
        stop.tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 90))
    }

    func testLiveScratchScreenshot() throws {
        guard LabUI.active || ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "screenshot" else {
            throw XCTSkip("Screenshot capture is not enabled.")
        }
        let app: XCUIApplication
        if LabUI.active {
            app = try startLaneConversation("Lab screenshot session", project: "Lab screenshots")
        } else {
            app = launchWork()
            guard openScratchSession(app), app.staticTexts["最新の回答"].waitForExistence(timeout: 30) else {
                XCTFail("Scratch session detail did not load."); return
            }
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "14i-session-detail"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // The dedicated relay serves a synthetic Project and a 412; no existing
    // Project is changed while testing the explicit conflict choice.
    func testProjectInstructionConflictChoice() throws {
        if LabUI.active { try laneProjectConflict(name: "Lab conflict choice"); return }
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "projectconflict" else {
            throw XCTSkip("Explicit Project-conflict fixture is not enabled.")
        }
        let app = launchWork()
        XCTAssertTrue(app.buttons["Projects"].waitForExistence(timeout: 30))
        app.buttons["work.section.projects"].tap()
        let project = app.staticTexts["LAA 14i conflict test"]
        guard project.waitForExistence(timeout: 30) else {
            XCTFail("The synthetic Project did not load.")
            return
        }
        project.tap()
        guard app.staticTexts["Server original"].waitForExistence(timeout: 20) else {
            XCTFail("The original instruction body did not load.")
            return
        }
        app.buttons["Edit"].tap()
        let instructions = app.textViews["work.project.instructions"]
        guard instructions.waitForExistence(timeout: 10) else {
            XCTFail("Instruction editing was not available.")
            return
        }
        instructions.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.1)).tap()
        instructions.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Server original".count))
        guard (instructions.value as? String ?? "").isEmpty else {
            XCTFail("The synthetic instruction body could not be cleared.")
            return
        }
        instructions.typeText("My revision")
        guard instructions.value as? String == "My revision" else {
            XCTFail("The local instruction edit did not match.")
            return
        }
        app.buttons["Save"].tap()
        guard app.staticTexts["現在の指示:"].waitForExistence(timeout: 20) else {
            XCTFail("The Project conflict was not shown.")
            return
        }
        XCTAssertTrue(app.staticTexts["Server revision"].exists)
        XCTAssertTrue(app.staticTexts["My revision"].exists)
        let adopt = app.buttons["現在の内容を使う"]
        XCTAssertTrue(adopt.isEnabled)
        adopt.tap()
        XCTAssertEqual(instructions.value as? String, "Server revision")
    }

    func testLiveFullEditorDraftSurvivesRelaunch() throws {
        continueAfterFailure = false
        let app: XCUIApplication
        if LabUI.active {
            app = try pairedLaneWork()
        } else {
            app = launchWork()
            if app.buttons["work.connect"].waitForExistence(timeout: 3) {
                throw XCTSkip("Run the integration lane or pair the dedicated test simulator before this flow.")
            }
        }
        let sessions = app.buttons["work.section.sessions"]
        XCTAssertTrue(sessions.waitForExistence(timeout: 10)); sessions.tap()
        let add = app.buttons["work.create"]
        XCTAssertTrue(waitUntilReady(add), "Paired Sessions did not open")
        add.tap(); app.buttons["work.sessions.new"].tap()
        let expand = app.buttons["入力欄を広げる"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        expand.tap()
        let full = app.textViews["work.launch.composer.fullEditor.field"]
        XCTAssertTrue(full.waitForExistence(timeout: 10))
        full.tap()
        full.typeText("Draft survives relaunch")
        app.buttons["composer.collapse-editor"].tap()
        let inline = app.textViews["work.launch.composer.field"]
        XCTAssertTrue(inline.waitForExistence(timeout: 10))
        XCTAssertTrue((inline.value as? String ?? "").contains("Draft survives relaunch"))
        app.buttons["閉じる"].tap()
        app.terminate()
        app.launchInLab()
        let work = app.buttons["Work"]
        XCTAssertTrue(work.waitForExistence(timeout: 30)); work.tap()
        XCTAssertTrue(sessions.waitForExistence(timeout: 10)); sessions.tap()
        XCTAssertTrue(waitUntilReady(add), "Paired Sessions did not reopen")
        XCTAssertFalse(app.buttons["work.connect"].exists, "the isolated pairing must survive a process restart")
        add.tap(); app.buttons["work.sessions.new"].tap()
        let restored = app.textViews["work.launch.composer.field"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertTrue((restored.value as? String ?? "").contains("Draft survives relaunch"))
    }
    // Opt-in screenshots of Sessions, the launcher, Projects and a project on a
    // simulator paired with a seeded throwaway Bridge.
    func testCaptureSessionsAndProjectsDesign() throws {
        try XCTSkipIf(LabUI.active, "Curated design capture requires a pinned session, the named project and its named file; not the Echo lane's generic seed.")
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_SCREENSHOT"] == "sessions" else {
            throw XCTSkip("Explicit sessions screenshots are not enabled.")
        }
        let appearance = ProcessInfo.processInfo.environment["LAA_WORK_LIVE_APPEARANCE"] ?? "light"
        let app = launchWork()
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "sessions-ui-\(name)-\(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(waitUntilReady(app.buttons["work.create"], timeout: 30))
        XCTAssertTrue(app.staticTexts["ピン留め"].waitForExistence(timeout: 30))
        shot("sessions")
        app.buttons["work.create"].tap(); app.buttons["work.sessions.new"].tap()
        XCTAssertTrue(app.navigationBars["新しいセッション"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["work.launch.favorite"].waitForExistence(timeout: 10))
        if app.buttons["work.launch.favorite"].label == "お気に入りに登録" { app.buttons["work.launch.favorite"].tap() }
        shot("launcher")
        app.buttons["work.launch.model"].tap()
        shot("model-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        let close = app.buttons["閉じる"]
        XCTAssertTrue(waitUntilReady(close, timeout: 10))
        close.tap()
        app.buttons["work.section.projects"].tap()
        XCTAssertTrue(app.buttons["work.projects.new"].waitForExistence(timeout: 10))
        let project = app.staticTexts["トレード｜環境認識"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 30))
        shot("projects")
        project.tap()
        XCTAssertTrue(app.buttons["work.project.newSession"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["手法メモ v3.md"].waitForExistence(timeout: 30))
        shot("project")
    }

    /// An empty conversation still opens on its follow-up field, and a session
    /// waiting for the owner opens on the decision rather than on old history.
    func testEmptyAndWaitingDecisionSessionsOpenInPlace() throws {
        try XCTSkipIf(LabUI.active, "Echo emits a reply and does not request a decision; those two seeded states are exercised by the separate Work UI fixture.")
        let empty = ProcessInfo.processInfo.environment["LAA_WORK_LIVE_EMPTY_SESSION_ID"] ?? ""
        let waiting = ProcessInfo.processInfo.environment["LAA_WORK_LIVE_DECISION_SESSION_ID"] ?? ""
        guard !empty.isEmpty || !waiting.isEmpty else {
            throw XCTSkip("Set LAA_WORK_LIVE_EMPTY_SESSION_ID or LAA_WORK_LIVE_DECISION_SESSION_ID.")
        }
        let app = launchWork()
        if !empty.isEmpty {
            XCTAssertTrue(openSession(app, id: empty))
            XCTAssertTrue(app.staticTexts["会話はまだありません。"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.descendants(matching: .any)["work.composer.field"].firstMatch.isHittable)
            app.navigationBars.firstMatch.buttons.firstMatch.tap()
        }
        if !waiting.isEmpty {
            XCTAssertTrue(openSession(app, id: waiting))
            // A waiting decision still opens at the bottom; the field explains
            // why it cannot send, and the decision itself is reachable above.
            let field = app.descendants(matching: .any)["work.composer.field"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 20))
            XCTAssertTrue(field.isHittable)
            XCTAssertTrue(app.staticTexts["判断待ち・停止中は追加送信できません。状態を確認してください。"].exists)
        }
    }

    /// Opening a session lands on its latest turn with the follow-up field and
    /// the model bar on screen. Scrolling up to read history must stop the
    /// follow, so a later poll cannot pull the owner back to the bottom.
    func testSessionOpensAtTheComposerAndStopsFollowingWhileReadingHistory() throws {
        try XCTSkipIf(LabUI.active, "Requires a long history and a timed new turn while reading; the separate Work UI fixture controls those events.")
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_SCROLL"] == "1" else {
            throw XCTSkip("Set LAA_WORK_LIVE_SCROLL=1 with a long live session.")
        }
        let app = launchWork()
        guard openScratchSession(app) else { XCTFail("The live session did not open."); return }
        let field = app.descendants(matching: .any)["work.composer.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        XCTAssertTrue(field.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["work.session.settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["work.session.fast"].exists)
        app.scrollViews.firstMatch.swipeDown()
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertFalse(field.isHittable)
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(field.isHittable)
    }
}
#endif
