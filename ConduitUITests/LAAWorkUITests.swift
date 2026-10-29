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
        XCTAssertTrue(app.buttons["新しいセッション"].waitForExistence(timeout: 30))
        app.buttons["新しいセッション"].tap()
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
        XCTAssertTrue(add.waitForExistence(timeout: 30))
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
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        let loading = app.progressIndicators["読み込み中"]
        if loading.exists {
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading)
            waitForExpectations(timeout: 30)
        }
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
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "workspace" else {
            throw XCTSkip("Explicit scratch-workspace creation is not enabled.")
        }
        let app = launchWork()
        let add = app.buttons["新しいセッション"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        let loading = app.progressIndicators["読み込み中"]
        if loading.exists {
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading)
            waitForExpectations(timeout: 30)
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
        create.tap()
        let newWorkspace = app.navigationBars["新しい作業場所"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: newWorkspace)
        waitForExpectations(timeout: 90)
        XCTAssertTrue(app.navigationBars["新しいセッション"].exists)
    }

    // Separating workspace creation from session creation makes each external
    // write observable before the next one is attempted.
    func testLiveCreateScratchSession() throws {
        guard ProcessInfo.processInfo.environment["LAA_WORK_LIVE_STAGE"] == "session" else {
            throw XCTSkip("Explicit scratch-session creation is not enabled.")
        }
        let app = launchWork()
        let add = app.buttons["新しいセッション"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        let loading = app.progressIndicators["読み込み中"]
        if loading.exists {
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading)
            waitForExpectations(timeout: 30)
        }
        add.tap()
        let picker = app.descendants(matching: .any)["work.session.workspace"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        let workspace = app.buttons.matching(
            NSPredicate(format: "label ENDSWITH %@", " · laa/14i-validation-20261029")
        ).firstMatch
        guard workspace.waitForExistence(timeout: 10) else {
            XCTFail("The designated scratch workspace is unavailable.")
            return
        }
        workspace.tap()
        guard picker.label.hasSuffix(" · laa/14i-validation-20261029") else {
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
        prompt.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        if !previous.isEmpty {
            prompt.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        guard (prompt.value as? String ?? "").isEmpty else {
            XCTFail("The existing scratch-session draft could not be cleared.")
            return
        }
        prompt.typeText("Reply exactly 14i-ready. Do not change files.")
        guard profile.value as? String == "deepseek-flash-high",
              name.value as? String == "LAA 14i validation",
              prompt.value as? String == "Reply exactly 14i-ready. Do not change files." else {
            XCTFail("The scratch-session fields do not match their intended values.")
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
        start.tap()
        XCTAssertTrue(app.staticTexts["セッションを開始しました"].waitForExistence(timeout: 120))
        XCTAssertTrue(app.buttons["セッションを開く"].exists)
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
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        let expand = app.buttons["全画面で入力"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        expand.tap()
        let full = app.textViews["work.composer.fullEditor.field"]
        XCTAssertTrue(full.waitForExistence(timeout: 10))
        full.tap()
        full.typeText("Draft survives relaunch")
        app.buttons["composer.collapse-editor"].tap()
        app.buttons["閉じる"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        let restored = app.textViews["work.composer.field"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertTrue((restored.value as? String ?? "").contains("Draft survives relaunch"))
    }
}
#endif
