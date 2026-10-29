#if LAA_BUILD
import XCTest

final class LAAWorkUITests: XCTestCase {
    private func launchWork() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "work"]
        if let appearance = ProcessInfo.processInfo.environment["LAA_WORK_LIVE_APPEARANCE"],
           ["light", "dark"].contains(appearance) {
            app.launchArguments += ["-conduit.themePreference", appearance]
        }
        app.launch()
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
        guard waitUntilReady(app.buttons["新しいセッション"]) else { return false }
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
        guard waitUntilReady(app.buttons["新しいセッション"]) else { return false }
        app.buttons["プロジェクト"].tap()
        let row = app.staticTexts["LAA 14i Project Test 20261029"].firstMatch
        guard row.waitForExistence(timeout: 30), reveal(row, in: app) else { return false }
        row.tap()
        return app.navigationBars["プロジェクト"].waitForExistence(timeout: 30)
    }

    private func enterDedicatedAddress(_ address: XCUIElement) -> Bool {
        guard address.waitForExistence(timeout: 10) else { return false }
        for _ in 0..<4 {
            let existing = address.value as? String ?? ""
            if existing.isEmpty || existing == "接続先" { break }
            address.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        let remaining = address.value as? String ?? ""
        guard remaining.isEmpty || remaining == "接続先" else {
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
        let connect = app.buttons["Macに接続する"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        connect.tap()
        XCTAssertTrue(enterDedicatedAddress(app.textFields["laa.bridge.address"]))
    }

    func testUnpairedWorkOffersPairing() throws {
        let app = launchWork()
        let connect = app.buttons["Macに接続する"]
        guard connect.waitForExistence(timeout: 15) else {
            if app.buttons["新しいセッション"].exists {
                throw XCTSkip("This simulator is already paired; the live flow covers its Work screen.")
            }
            XCTFail("Neither the unpaired nor the paired Work screen appeared.")
            return
        }
        XCTAssertTrue(app.staticTexts["未接続"].exists)
        connect.tap()
        XCTAssertTrue(app.navigationBars["Macとの接続"].waitForExistence(timeout: 5) || app.textFields.count > 0)
    }

    // This helper is opt-in on a dedicated simulator. The one-time code is
    // pasted from its clipboard, so XCTest never receives it as typed text.
    func testPairDedicatedSimulator() throws {
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_PAIR"] == "1" else {
            throw XCTSkip("Explicit live pairing is not enabled.")
        }
        let app = launchWork()
        let connect = app.buttons["Macに接続する"]
        guard connect.waitForExistence(timeout: 15) else {
            if app.buttons["新しいセッション"].exists {
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
        code.press(forDuration: 1)
        let paste = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Paste", "ペースト"])).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        app.buttons["laa.bridge.pair"].tap()
        guard app.buttons["新しいセッション"].waitForExistence(timeout: 30) else {
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
        XCTAssertFalse(app.buttons["新しいセッション"].isEnabled)
    }

    func testLiveEmptySessionList() throws {
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_EMPTY"] == "1" else {
            throw XCTSkip("Explicit live empty-response injection is not enabled.")
        }
        let app = launchWork()
        XCTAssertTrue(app.staticTexts["セッションがありません。＋から始められます。"].waitForExistence(timeout: 30))
    }

    func testCaptureLiveSessionList() throws {
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_SCREENSHOT"] == "1" else {
            throw XCTSkip("Explicit live screenshots are not enabled.")
        }
        let app = launchWork()
        XCTAssertTrue(app.buttons["新しいセッション"].waitForExistence(timeout: 30))
        if ProcessInfo.processInfo.environment["LAA_WORK_LIVE_EMPTY"] == "1" {
            XCTAssertTrue(app.staticTexts["セッションがありません。＋から始められます。"].waitForExistence(timeout: 30))
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
        if app.buttons["Macに接続する"].waitForExistence(timeout: 3) {
            throw XCTSkip("Pair the dedicated test simulator with the real Bridge before this flow.")
        }
        let add = app.buttons["新しいセッション"]
        guard waitUntilReady(add) else { XCTFail("Session data did not finish loading."); return }
        add.tap()
        XCTAssertTrue(app.navigationBars["新しいセッション"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["入力の文字サイズ"].exists)
        XCTAssertTrue(app.buttons["全画面で入力"].exists)
        app.buttons["閉じる"].tap()
        app.buttons["タスク"].tap()
        XCTAssertTrue(app.staticTexts["Linearが現在のタスクの正本です。ここでは閲覧のみできます。"].waitForExistence(timeout: 30))
        app.buttons["ルーティン"].tap()
        XCTAssertTrue(app.staticTexts["準備中"].waitForExistence(timeout: 5))
    }

    func testLiveWorkspaceCreationEntry() throws {
        let app = launchWork()
        if app.buttons["Macに接続する"].waitForExistence(timeout: 3) {
            throw XCTSkip("Pair the dedicated test simulator with the real Bridge before this flow.")
        }
        let add = app.buttons["新しいセッション"]
        guard waitUntilReady(add) else { XCTFail("Session data did not finish loading."); return }
        add.tap()
        let createWorkspace = app.buttons["作業場所を新しく作る"]
        XCTAssertTrue(createWorkspace.waitForExistence(timeout: 10))
        createWorkspace.tap()
        XCTAssertTrue(app.navigationBars["新しい作業場所"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["work.workspace.name"].exists)
        XCTAssertTrue(app.textFields["work.workspace.branch"].exists)
        XCTAssertFalse(app.buttons["work.workspace.create"].isEnabled)
    }

    func testLiveWorkspaceRepositoryMenu() throws {
        let app = launchWork()
        if app.buttons["Macに接続する"].waitForExistence(timeout: 3) {
            throw XCTSkip("Pair the dedicated test simulator with the real Bridge before this flow.")
        }
        let add = app.buttons["新しいセッション"]
        guard waitUntilReady(add) else { XCTFail("Session data did not finish loading."); return }
        add.tap()
        app.buttons["作業場所を新しく作る"].tap()
        let picker = app.descendants(matching: .any)["work.workspace.repo"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        let repo = app.buttons["~/dev/hermes-conduit"]
        XCTAssertTrue(repo.waitForExistence(timeout: 10))
        repo.tap()
        XCTAssertTrue(picker.staticTexts["~/dev/hermes-conduit"].exists)
    }

    // This test creates one named scratch worktree only when explicitly
    // enabled for the dedicated simulator. It must be archived afterwards.
    func testLiveCreateScratchWorkspace() throws {
        let stage = ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"]
        guard stage == "workspace" || stage == "workspace-preflight" else {
            throw XCTSkip("Explicit scratch-workspace creation is not enabled.")
        }
        let app = launchWork()
        let add = app.buttons["新しいセッション"]
        guard waitUntilReady(add) else {
            let known = ["取得できませんでした", "Macからの応答を読み取れませんでした。",
                         "Macに届きません。TailscaleとMacの接続を確認してください。",
                         "Mac側のサービスを利用できません。"]
            XCTFail("Session data did not finish loading: \(known.filter { app.staticTexts[$0].exists }.joined(separator: " / "))")
            return
        }
        add.tap()
        app.buttons["作業場所を新しく作る"].tap()
        let picker = app.descendants(matching: .any)["work.workspace.repo"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        let repo = app.buttons["~/dev/hermes-conduit"]
        guard repo.waitForExistence(timeout: 10) else {
            XCTFail("The designated repository is unavailable.")
            return
        }
        repo.tap()
        guard picker.staticTexts["~/dev/hermes-conduit"].exists else {
            XCTFail("The designated repository was not selected.")
            return
        }
        let name = app.textFields["work.workspace.name"]
        name.tap()
        name.typeText("LAA-14i-validation-20261029")
        let branch = app.textFields["work.workspace.branch"]
        branch.tap()
        branch.typeText("laa/14i-validation-20261029")
        guard name.value as? String == "LAA-14i-validation-20261029",
              branch.value as? String == "laa/14i-validation-20261029" else {
            XCTFail("The scratch-workspace fields do not match their intended values.")
            return
        }
        let create = app.buttons["work.workspace.create"]
        guard create.isEnabled else {
            XCTFail("Scratch-workspace creation is not ready.")
            return
        }
        if stage == "workspace-preflight" { return }
        create.tap()
        let newWorkspace = app.navigationBars["新しい作業場所"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: newWorkspace)
        waitForExpectations(timeout: 90)
        XCTAssertTrue(app.navigationBars["新しいセッション"].exists)
    }

    // Separating workspace creation from session creation makes each external
    // write observable before the next one is attempted.
    func testLiveCreateScratchSession() throws {
        let stage = ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"]
        guard stage == "session" || stage == "session-preflight" else {
            throw XCTSkip("Explicit scratch-session creation is not enabled.")
        }
        let app = launchWork()
        let add = app.buttons["新しいセッション"]
        guard waitUntilReady(add) else { XCTFail("Session data did not finish loading."); return }
        add.tap()
        let projectPicker = app.descendants(matching: .any)["work.session.project"].firstMatch
        guard projectPicker.waitForExistence(timeout: 10) else { XCTFail("Project picker unavailable."); return }
        projectPicker.tap()
        let testProject = app.buttons["LAA 14i Project Test 20261029"]
        guard testProject.waitForExistence(timeout: 10) else { XCTFail("Scratch Project unavailable."); return }
        testProject.tap()
        guard projectPicker.label.contains("LAA 14i Project Test 20261029") else {
            XCTFail("Scratch Project was not selected."); return
        }
        let picker = app.descendants(matching: .any)["work.session.workspace"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        let workspace = app.buttons.matching(
            NSPredicate(format: "label ENDSWITH %@", " · laa-14i-validation-20261029")
        ).firstMatch
        guard workspace.waitForExistence(timeout: 10) else {
            XCTFail("The designated scratch workspace is unavailable.")
            return
        }
        workspace.tap()
        guard picker.label.hasSuffix(" · laa-14i-validation-20261029") else {
            XCTFail("The designated scratch workspace was not selected.")
            return
        }
        let profile = app.textFields["work.session.profile"]
        profile.tap()
        profile.typeText("deepseek-flash-high")
        let name = app.textFields["work.session.name"]
        name.tap()
        name.typeText("LAA 14i validation")
        let prompt = app.textViews["work.composer.field"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        let previous = prompt.value as? String ?? ""
        let expectedPrompt = "Reply exactly 14i-ready. Do not change files."
        if previous != expectedPrompt {
            app.buttons["全画面で入力"].tap()
            let full = app.textViews["work.composer.fullEditor.field"]
            guard full.waitForExistence(timeout: 10) else { XCTFail("Full editor unavailable."); return }
            full.tap()
            if !previous.isEmpty {
                full.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
            }
            guard (full.value as? String ?? "").isEmpty else {
                XCTFail("The existing scratch-session draft could not be cleared."); return
            }
            full.typeText(expectedPrompt)
            guard full.value as? String == expectedPrompt else { XCTFail("Scratch prompt did not match."); return }
            app.buttons["composer.collapse-editor"].tap()
        }
        let profileMatches = profile.value as? String == "deepseek-flash-high"
        let nameMatches = name.value as? String == "LAA 14i validation"
        let promptMatches = prompt.value as? String == expectedPrompt
        guard profileMatches, nameMatches, promptMatches else {
            XCTFail("Scratch fields did not match: profile=\(profileMatches), name=\(nameMatches), prompt=\(promptMatches).")
            return
        }
        let confirm = app.buttons["work.composer.send"]
        guard confirm.isEnabled else {
            XCTFail("Scratch-session confirmation is not ready.")
            return
        }
        confirm.tap()
        let start = app.buttons["セッションを開始"]
        guard start.waitForExistence(timeout: 10) else {
            XCTFail("Scratch-session confirmation did not appear.")
            return
        }
        if stage == "session-preflight" { return }
        start.tap()
        XCTAssertTrue(app.staticTexts["セッションを開始しました"].waitForExistence(timeout: 120))
        XCTAssertTrue(app.buttons["セッションを開く"].exists)
    }

    // Each opt-in mutation is isolated so an uncertain result is never retried
    // as a new write without first reconciling the Bridge state.
    func testLiveCreateScratchProject() throws {
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "project-create" else {
            throw XCTSkip("Explicit scratch-Project creation is not enabled.")
        }
        let app = launchWork()
        guard waitUntilReady(app.buttons["新しいセッション"]) else { XCTFail("Work did not load."); return }
        app.buttons["プロジェクト"].tap()
        let add = app.buttons["新しいプロジェクト"]
        guard waitUntilReady(add) else { XCTFail("Project creation unavailable."); return }
        add.tap()
        let name = app.textFields["プロジェクト名"]
        guard name.waitForExistence(timeout: 10), ["", "プロジェクト名"].contains(name.value as? String ?? "") else {
            XCTFail("The scratch Project name field was not empty."); return
        }
        name.tap()
        name.typeText("LAA 14i Project Test 20261029")
        guard name.value as? String == "LAA 14i Project Test 20261029" else { XCTFail("Wrong Project name."); return }
        let save = app.buttons["保存"]
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
        app.buttons["編集"].tap()
        let instructions = app.textViews["work.project.instructions"]
        guard instructions.waitForExistence(timeout: 10), (instructions.value as? String ?? "").isEmpty else {
            XCTFail("The scratch Project instructions were not empty."); return
        }
        instructions.tap()
        instructions.typeText("Reply only as asked. Do not modify files.")
        guard instructions.value as? String == "Reply only as asked. Do not modify files." else {
            XCTFail("The scratch instruction body did not match."); return
        }
        app.buttons["保存"].tap()
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
        app.buttons["編集"].tap()
        let instructions = app.textViews["work.project.instructions"]
        guard instructions.waitForExistence(timeout: 10) else { XCTFail("Instruction editor unavailable."); return }
        instructions.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.1)).tap()
        instructions.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Reply only as asked. Do not modify files.".count))
        guard (instructions.value as? String ?? "").isEmpty else { XCTFail("Could not clear test instructions."); return }
        instructions.typeText("My 14i revision")
        guard instructions.value as? String == "My 14i revision" else { XCTFail("The test edit did not match."); return }
        app.buttons["保存"].tap()
        guard app.staticTexts["現在の指示:"].waitForExistence(timeout: 30) else {
            XCTFail("The real Bridge conflict was not shown."); return
        }
        XCTAssertTrue(app.staticTexts["Reply only as asked. Do not modify files."].exists)
        XCTAssertTrue(app.staticTexts["My 14i revision"].exists)
        let adopt = app.buttons["現在の版を採用"]
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
        let stop = app.buttons["停止"]
        guard reveal(stop, in: app), stop.isEnabled else { XCTFail("Stop unavailable."); return }
        stop.tap()
        XCTAssertTrue(app.buttons["続きの指示を入力"].waitForExistence(timeout: 90))
    }

    func testLiveScratchResume() throws {
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "resume" else { throw XCTSkip("Resume is not enabled.") }
        let app = launchWork()
        guard openScratchSession(app) else { XCTFail("Scratch session unavailable."); return }
        let resume = app.buttons["続きの指示を入力"]
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
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "後継:")).firstMatch.waitForExistence(timeout: 120))
    }

    func testLiveScratchStopSuccessor() throws {
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "stop-successor" else { throw XCTSkip("Successor cleanup is not enabled.") }
        let app = launchWork()
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_SESSION_ID"]?.isEmpty == false,
              openScratchSession(app),
              app.staticTexts["○ 確認待ち"].waitForExistence(timeout: 180) else {
            XCTFail("The designated scratch successor did not reach review."); return
        }
        let stop = app.buttons["停止"]
        guard reveal(stop, in: app), stop.isEnabled else { XCTFail("Successor stop unavailable."); return }
        stop.tap()
        XCTAssertTrue(app.buttons["続きの指示を入力"].waitForExistence(timeout: 90))
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
        XCTAssertTrue(app.buttons["プロジェクト"].waitForExistence(timeout: 30))
        app.buttons["プロジェクト"].tap()
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
        app.buttons["編集"].tap()
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
        app.buttons["保存"].tap()
        guard app.staticTexts["現在の指示:"].waitForExistence(timeout: 20) else {
            XCTFail("The Project conflict was not shown.")
            return
        }
        XCTAssertTrue(app.staticTexts["Server revision"].exists)
        XCTAssertTrue(app.staticTexts["My revision"].exists)
        let adopt = app.buttons["現在の版を採用"]
        XCTAssertTrue(adopt.isEnabled)
        adopt.tap()
        XCTAssertEqual(instructions.value as? String, "Server revision")
    }

    func testLiveFullEditorDraftSurvivesRelaunch() throws {
        let app = launchWork()
        if app.buttons["Macに接続する"].waitForExistence(timeout: 3) {
            throw XCTSkip("Pair the dedicated test simulator with the real Bridge before this flow.")
        }
        let add = app.buttons["新しいセッション"]
        guard waitUntilReady(add) else { XCTFail("Session data did not finish loading."); return }
        add.tap()
        let expand = app.buttons["全画面で入力"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        expand.tap()
        let full = app.textViews["work.composer.fullEditor.field"]
        XCTAssertTrue(full.waitForExistence(timeout: 10))
        full.tap()
        full.typeText("Draft survives relaunch")
        app.buttons["composer.collapse-editor"].tap()
        let inline = app.textViews["work.composer.field"]
        XCTAssertTrue((inline.value as? String ?? "").contains("Draft survives relaunch"))
        app.buttons["閉じる"].tap()
        app.terminate()
        app.launch()
        guard waitUntilReady(add) else { XCTFail("Session data did not finish reloading."); return }
        add.tap()
        let restored = app.textViews["work.composer.field"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertTrue((restored.value as? String ?? "").contains("Draft survives relaunch"))
    }
}
#endif
