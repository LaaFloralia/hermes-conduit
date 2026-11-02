#if LAA_BUILD
import XCTest

final class LAAWorkUITests: XCTestCase {
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
        app.launch()
        let work = app.buttons["Sessions, projects and tasks"]
        XCTAssertTrue(work.waitForExistence(timeout: 30))
        work.tap()
        return app
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

    private func openScratchSession(_ app: XCUIApplication) -> Bool {
        guard waitUntilReady(app.buttons["work.sessions.new"]) else { return false }
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
        guard waitUntilReady(app.buttons["work.sessions.new"]) else { return false }
        app.buttons["Projects"].tap()
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
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_ADDRESS"] == "1" else {
            throw XCTSkip("Explicit address-entry diagnostic is not enabled.")
        }
        let app = launchWork()
        let connect = app.buttons["Connect to Mac"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        connect.tap()
        XCTAssertTrue(enterDedicatedAddress(app.textFields["laa.bridge.address"]))
    }

    func testUnpairedWorkOffersPairing() throws {
        let app = launchWork()
        let connect = app.buttons["Connect to Mac"]
        guard connect.waitForExistence(timeout: 15) else {
            if waitUntilReady(app.buttons["work.sessions.new"]) {
                throw XCTSkip("This simulator is already paired; the live flow covers its Work screen.")
            }
            XCTFail("Neither the unpaired nor the paired Work screen appeared.")
            return
        }
        XCTAssertTrue(app.staticTexts["未接続"].exists)
        connect.tap()
        XCTAssertTrue(app.navigationBars["Connect to Mac"].waitForExistence(timeout: 5) || app.textFields.count > 0)
    }

    func testWorkSegmentsAndRoutinePlaceholderWhenUnpaired() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launch()
        let work = app.buttons["Sessions, projects and tasks"]
        XCTAssertTrue(work.waitForExistence(timeout: 30))
        work.tap()
        XCTAssertTrue(app.buttons["Connect to Mac"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Sessions"].exists)
        XCTAssertTrue(app.buttons["Projects"].exists)
        XCTAssertTrue(app.buttons["Tasks"].exists)
        app.buttons["Routines"].tap()
        XCTAssertTrue(app.buttons["Connect to Mac"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["ルーティンはありません。"].exists)
        app.buttons["Sessions"].tap()
        XCTAssertTrue(app.buttons["Connect to Mac"].waitForExistence(timeout: 5))
        if app.buttons["work.sessions.new"].exists { XCTAssertFalse(app.buttons["work.sessions.new"].isEnabled) }
    }

    func testOwnerTasksAndPendingAreAvailableWithoutPairing() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launch()
        let work = app.buttons["Sessions, projects and tasks"]
        XCTAssertTrue(work.waitForExistence(timeout: 30)); work.tap()
        XCTAssertTrue(app.buttons["Tasks"].waitForExistence(timeout: 15))
        app.buttons["Tasks"].tap()
        let input = app.textFields["タスクを追加"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(input.isEnabled)
        XCTAssertFalse(app.staticTexts["Linearが現在のタスクの正本です。ここでは閲覧のみできます。"].exists)
        let pending = app.buttons["work.ownerTasks.pending"]
        XCTAssertTrue(pending.exists)
        pending.tap()
        XCTAssertTrue(app.navigationBars["送信待ち・下書き"].waitForExistence(timeout: 5))
    }

    private func captureUnpairedDesign(_ appearance: String) {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                                "-conduit.themePreference", appearance]
        app.launch()
        let work = app.buttons["Sessions, projects and tasks"]
        XCTAssertTrue(work.waitForExistence(timeout: 30))
        work.tap()
        XCTAssertTrue(app.buttons["Connect to Mac"].waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "v2-work-unpaired-\(appearance)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCaptureDesignUnpairedLight() { captureUnpairedDesign("light") }
    func testCaptureDesignUnpairedDark() { captureUnpairedDesign("dark") }

    // This helper is opt-in on a dedicated simulator. The one-time code is
    // pasted from its clipboard, so XCTest never receives it as typed text.
    func testPairDedicatedSimulator() throws {
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_PAIR"] == "1" else {
            throw XCTSkip("Explicit live pairing is not enabled.")
        }
        let app = launchWork()
        let connect = app.buttons["Connect to Mac"]
        guard connect.waitForExistence(timeout: 15) else {
            if waitUntilReady(app.buttons["work.sessions.new"]) {
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
        guard waitUntilReady(app.buttons["work.sessions.new"], timeout: 30) else {
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
        XCTAssertFalse(app.buttons["work.sessions.new"].isEnabled)
    }

    func testLiveEmptySessionList() throws {
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_EMPTY"] == "1" else {
            throw XCTSkip("Explicit live empty-response injection is not enabled.")
        }
        let app = launchWork()
        XCTAssertTrue(app.staticTexts["セッションはまだありません。"].waitForExistence(timeout: 30))
    }

    func testCaptureLiveSessionList() throws {
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_SCREENSHOT"] == "1" else {
            throw XCTSkip("Explicit live screenshots are not enabled.")
        }
        let app = launchWork()
        XCTAssertTrue(waitUntilReady(app.buttons["work.sessions.new"], timeout: 30))
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
        let app = launchWork()
        if app.buttons["Connect to Mac"].waitForExistence(timeout: 3) {
            throw XCTSkip("Pair the dedicated test simulator with the real Bridge before this flow.")
        }
        let add = app.buttons["work.sessions.new"]
        guard waitUntilReady(add) else { XCTFail("Session data did not finish loading."); return }
        add.tap()
        XCTAssertTrue(app.navigationBars["新しいセッション"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Input Text Size"].exists)
        XCTAssertTrue(app.buttons["Full Screen Editor"].exists)
        app.buttons["閉じる"].tap()
        app.buttons["Projects"].tap()
        let addProject = app.buttons["work.projects.new"]
        XCTAssertTrue(addProject.waitForExistence(timeout: 10))
        addProject.tap()
        XCTAssertTrue(app.navigationBars["New Project"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Project Name"].exists)
        app.buttons["Close"].tap()
        app.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["Linearが現在のタスクの正本です。ここでは閲覧のみできます。"].waitForExistence(timeout: 30))
        app.buttons["Routines"].tap()
        XCTAssertTrue(app.staticTexts["準備中"].waitForExistence(timeout: 5))
    }

    // Separating workspace creation from session creation makes each external
    // write observable before the next one is attempted.
    func testLiveCreateScratchSession() throws {
        let stage = ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"]
        guard stage == "session" || stage == "session-preflight" else {
            throw XCTSkip("Explicit scratch-session creation is not enabled.")
        }
        let app = launchWork()
        let add = app.buttons["work.sessions.new"]
        guard waitUntilReady(add) else { XCTFail("Session data did not finish loading."); return }
        add.tap()
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
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "project-create" else {
            throw XCTSkip("Explicit scratch-Project creation is not enabled.")
        }
        let app = launchWork()
        guard waitUntilReady(app.buttons["work.sessions.new"]) else { XCTFail("Work did not load."); return }
        app.buttons["Projects"].tap()
        let add = app.buttons["work.projects.new"]
        guard waitUntilReady(add) else { XCTFail("Project creation unavailable."); return }
        add.tap()
        let name = app.textFields["Project Name"]
        guard name.waitForExistence(timeout: 10), ["", "Project Name"].contains(name.value as? String ?? "") else {
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
        let adopt = app.buttons["Use Current Version"]
        guard adopt.isEnabled else { XCTFail("Conflict choice unavailable."); return }
        adopt.tap()
        XCTAssertEqual(instructions.value as? String, "Reply only as asked. Do not modify files.")
    }

    func testLiveScratchHistoryRecovery() throws {
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
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "follow-up-readback" else { throw XCTSkip("Follow-up readback is not enabled.") }
        let app = launchWork()
        guard openScratchSession(app) else { XCTFail("Scratch session unavailable."); return }
        XCTAssertTrue(app.staticTexts["追加指示を送信"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["最新の回答"].exists)
    }

    func testLiveScratchStop() throws {
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
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "screenshot" else { throw XCTSkip("Screenshot capture is not enabled.") }
        let app = launchWork()
        guard openScratchSession(app), app.staticTexts["最新の回答"].waitForExistence(timeout: 30) else {
            XCTFail("Scratch session detail did not load."); return
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "14i-session-detail"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // The dedicated relay serves a synthetic Project and a 412; no existing
    // Project is changed while testing the explicit conflict choice.
    func testProjectInstructionConflictChoice() throws {
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "projectconflict" else {
            throw XCTSkip("Explicit Project-conflict fixture is not enabled.")
        }
        let app = launchWork()
        XCTAssertTrue(app.buttons["Projects"].waitForExistence(timeout: 30))
        app.buttons["Projects"].tap()
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
        let adopt = app.buttons["Use Current Version"]
        XCTAssertTrue(adopt.isEnabled)
        adopt.tap()
        XCTAssertEqual(instructions.value as? String, "Server revision")
    }

    func testLiveFullEditorDraftSurvivesRelaunch() throws {
        let app = launchWork()
        if app.buttons["Connect to Mac"].waitForExistence(timeout: 3) {
            throw XCTSkip("Pair the dedicated test simulator with the real Bridge before this flow.")
        }
        let add = app.buttons["work.sessions.new"]
        guard waitUntilReady(add) else { XCTFail("Session data did not finish loading."); return }
        add.tap()
        let expand = app.buttons["Full Screen Editor"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        expand.tap()
        let full = app.textViews["work.composer.fullEditor.field"]
        XCTAssertTrue(full.waitForExistence(timeout: 10))
        full.tap()
        full.typeText("Draft survives relaunch")
        app.buttons["composer.collapse-editor"].tap()
        let inline = app.textViews["work.composer.field"]
        XCTAssertTrue((inline.value as? String ?? "").contains("Draft survives relaunch"))
        app.buttons["Close"].tap()
        app.terminate()
        app.launch()
        let work = app.buttons["Sessions, projects and tasks"]
        XCTAssertTrue(work.waitForExistence(timeout: 30)); work.tap()
        guard waitUntilReady(add) else { XCTFail("Session data did not finish reloading."); return }
        add.tap()
        let restored = app.textViews["work.composer.field"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertTrue((restored.value as? String ?? "").contains("Draft survives relaunch"))
    }
    // Opt-in screenshots of Sessions, the launcher, Projects and a project on a
    // simulator paired with a seeded throwaway Bridge.
    func testCaptureSessionsAndProjectsDesign() throws {
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
        XCTAssertTrue(waitUntilReady(app.buttons["work.sessions.new"], timeout: 30))
        XCTAssertTrue(app.staticTexts["ピン留め"].waitForExistence(timeout: 30))
        shot("sessions")
        app.buttons["work.sessions.new"].tap()
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
        app.buttons["Projects"].tap()
        XCTAssertTrue(app.buttons["work.projects.new"].waitForExistence(timeout: 10))
        let project = app.staticTexts["トレード｜環境認識"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 30))
        shot("projects")
        project.tap()
        XCTAssertTrue(app.buttons["work.project.newSession"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["手法メモ v3.md"].waitForExistence(timeout: 30))
        shot("project")
    }
}
#endif
