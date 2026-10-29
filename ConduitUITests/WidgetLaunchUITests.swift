//
//  WidgetLaunchUITests.swift
//  ConduitUITests
//
//  These scenarios exercise the DEBUG-only fixture delivery path into the same
//  URL admission used by .onOpenURL. They do not simulate WidgetKit or prove
//  that an installed Home Screen widget delivered a tap.
//

import XCTest

final class WidgetLaunchUITests: XCTestCase {
    private enum Identity {
        static let connectedDashboard = "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD"
        static let seededProfiles = "-CONDUIT_UI_TEST_PROFILES"
        static let coldWidgetURL = "-CONDUIT_UI_TEST_WIDGET_URL"
        static let widgetDeliveryMode = "-CONDUIT_UI_TEST_WIDGET_DELIVERY"
        static let holdWidgetReadiness = "-CONDUIT_UI_TEST_WIDGET_HOLD_READINESS"
        static let persistentDraft = "-CONDUIT_UI_TEST_PERSISTENT_DRAFTS"
        static let deliverWidgetURL = "widgetUITestDeliverURL"

        // The DEBUG fixture seeds this deterministic workspace and one saved
        // conversation before it admits a launch URL. It must use the normal
        // app URL-ingestion/coordinator path, not fake the visible outcome.
        static let dashboardID = "8D516B21-6B3C-4F5A-A0D6-6F6E8B73A901"
        static let profile = "work"
        static let sessionID = "widget-ui-test-session"

        // Machine-readable outcome surfaces owned by the DEBUG fixture. They
        // expose app state/presentation, never claim that audio was captured.
        static let workspaceOutcome = "widgetUITestWorkspace"
        static let conversationOutcome = "widgetUITestConversation"
        static let freshConversationOutcome = "widgetUITestFreshConversation"
        static let deferredTalkOutcome = "widgetUITestTalkDeferred"
        static let recoveryOutcome = "widgetUITestRecovery"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testColdWidgetResumeOpensRequestedWorkspace() throws {
        let app = launchApp(coldURL: resumeURL)

        XCTAssertTrue(app.otherElements[Identity.workspaceOutcome].waitForExistence(timeout: 10), tree(app))
        XCTAssertEqual(app.otherElements[Identity.workspaceOutcome].value as? String, Identity.profile)
        XCTAssertTrue(app.otherElements[Identity.conversationOutcome].waitForExistence(timeout: 10), tree(app))
        XCTAssertEqual(app.otherElements[Identity.conversationOutcome].value as? String, Identity.sessionID)
    }

    func testWarmWidgetNewChatCreatesFreshConversation() throws {
        let app = launchApp(warmURL: newChatURL)
        let deliver = app.buttons[Identity.deliverWidgetURL]
        XCTAssertTrue(deliver.waitForExistence(timeout: 10), tree(app))

        deliver.tap()

        let freshConversation = app.otherElements[Identity.freshConversationOutcome]
        XCTAssertTrue(freshConversation.waitForExistence(timeout: 10), tree(app))
        XCTAssertTrue((freshConversation.value as? String)?.isEmpty == false, "New Chat must expose the identity created by the app operation. Tree:\n\(app.debugDescription)")
        XCTAssertNotEqual(freshConversation.value as? String, Identity.sessionID, "New Chat must not resume the seeded conversation")
    }

    func testWidgetTalkWaitsForForegroundReadiness() throws {
        let app = launchApp(warmURL: talkURL, holdReadiness: true)
        let deliver = app.buttons[Identity.deliverWidgetURL]
        XCTAssertTrue(deliver.waitForExistence(timeout: 10), tree(app))

        deliver.tap()

        let deferred = app.otherElements[Identity.deferredTalkOutcome]
        XCTAssertTrue(deferred.waitForExistence(timeout: 10), tree(app))
        XCTAssertEqual(deferred.value as? String, "waiting-for-foreground-readiness")
        // The fixture exposes this marker only while the real launch request
        // remains pending and the actual voice sheet/call are both inactive.
        // Audio non-activation is separately covered by Task 3's unit spies.
    }

    func testRemovedWidgetTargetShowsRecovery() throws {
        let app = launchApp(coldURL: missingConversationURL)

        let recovery = app.otherElements[Identity.recoveryOutcome]
        XCTAssertTrue(recovery.waitForExistence(timeout: 10), tree(app))
        XCTAssertEqual(recovery.value as? String, "conversation-unavailable")
        XCTAssertEqual(app.otherElements[Identity.workspaceOutcome].value as? String, Identity.profile, "Recovery must remain scoped to the requested workspace. Tree:\n\(app.debugDescription)")
        XCTAssertNotEqual(app.otherElements[Identity.conversationOutcome].value as? String, Identity.sessionID, "A missing conversation must not be replaced by the current conversation. Tree:\n\(app.debugDescription)")
    }

    func testFullEditorCanOpenAndCloseForAShortDraft() throws {
        let app = launchApp(coldURL: resumeURL, persistentDraftID: UUID())
        XCTAssertTrue(app.otherElements[Identity.conversationOutcome].waitForExistence(timeout: 15), tree(app))
        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), tree(app))
        field.tap()
        field.typeText("short")
        let expand = app.buttons["composer.expand-editor"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5), tree(app))
        expand.tap()
        let full = app.textViews["composer.fullEditor.field"]
        XCTAssertTrue(full.waitForExistence(timeout: 5), tree(app))
        XCTAssertEqual(full.value as? String, "short")
        full.typeText(" text")
        app.buttons["composer.collapse-editor"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5), tree(app))
        XCTAssertEqual(field.value as? String, "short text")
    }

    func testDraftSurvivesAppTerminationAndRelaunch() throws {
        let app = launchApp(coldURL: resumeURL, persistentDraftID: UUID())
        XCTAssertTrue(app.otherElements[Identity.conversationOutcome].waitForExistence(timeout: 15), tree(app))
        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), tree(app))
        field.tap()
        field.typeText("Draft survives relaunch")
        XCTAssertEqual(field.value as? String, "Draft survives relaunch")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.otherElements[Identity.conversationOutcome].waitForExistence(timeout: 15), tree(app))
        let restored = app.textViews["composer.field"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10), tree(app))
        XCTAssertEqual(restored.value as? String, "Draft survives relaunch")
    }

    func testUnknownDeliveryIsReviewedBeforeRestoringTheDraft() throws {
        let app = launchApp(coldURL: resumeURL, persistentDraftID: UUID(), unknownDelivery: true)
        let review = app.buttons["composer.unknown-delivery"]
        XCTAssertTrue(review.waitForExistence(timeout: 15), tree(app))
        review.tap()
        let restore = app.buttons["Restore to draft"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5), tree(app))
        restore.tap()
        let field = app.textViews["composer.field"]
        XCTAssertEqual(field.value as? String, "Interrupted message")
        app.terminate()
        app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 15), tree(app))
        XCTAssertEqual(field.value as? String, "Interrupted message")
        XCTAssertFalse(review.exists)
    }

    func testInputTextSizeIsIndependentAndPersists() throws {
        let app = launchApp(coldURL: resumeURL, persistentDraftID: UUID())
        func openChatSettings() {
            let settings = app.buttons.matching(NSPredicate(
                format: "identifier == %@ OR label == %@ OR label == %@", "gearshape", "Settings", "設定"
            )).firstMatch
            app.returnToV2Tabs(revealing: settings)
            if !settings.exists, app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() }
            XCTAssertTrue(settings.waitForExistence(timeout: 10), tree(app))
            settings.tap()
            let chat = app.buttons["settings.chat"]
            for _ in 0..<6 where !chat.isHittable { app.swipeUp() }
            XCTAssertTrue(chat.waitForExistence(timeout: 5), tree(app))
            chat.tap()
        }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<10 where !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.isHittable, tree(app))
        }
        openChatSettings()
        let input = app.sliders["settings.input-text-size"]
        let response = app.sliders["settings.chat-text-size"]
        reveal(input)
        let responseValue = response.value as? String
        input.adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(input.value as? String, "Smallest")
        input.adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(input.value as? String, "Largest")
        XCTAssertEqual(response.value as? String, responseValue)
        app.terminate()
        app.launch()
        openChatSettings()
        reveal(input)
        XCTAssertEqual(input.value as? String, "Largest")
        input.adjust(toNormalizedSliderPosition: 0.75)
    }

    // MARK: - Launch fixture

    private var resumeURL: URL {
        widgetURL(action: "resume", includeConversation: true)
    }

    private var missingConversationURL: URL {
        widgetURL(action: "resume", includeConversation: true, sessionID: "evicted-widget-ui-test-session")
    }

    private var newChatURL: URL {
        widgetURL(action: "newChat", includeConversation: false)
    }

    private var talkURL: URL {
        widgetURL(action: "talk", includeConversation: false)
    }

    private func widgetURL(action: String, includeConversation: Bool, sessionID: String = Identity.sessionID) -> URL {
        var components = URLComponents()
        components.scheme = "conduit"
        components.host = "widget"
        components.path = "/v1/\(action)"
        var items = [
            URLQueryItem(name: "dashboard", value: Identity.dashboardID.lowercased()),
            URLQueryItem(name: "profile", value: Identity.profile)
        ]
        if includeConversation {
            items += [
                URLQueryItem(name: "kind", value: "dashboard"),
                URLQueryItem(name: "scope", value: Identity.profile),
                URLQueryItem(name: "session", value: sessionID),
                URLQueryItem(name: "unverified", value: "false")
            ]
        }
        components.queryItems = items
        guard let url = components.url else { preconditionFailure("Widget fixture URL must be valid") }
        return url
    }

    private func launchApp(coldURL: URL? = nil, warmURL: URL? = nil, holdReadiness: Bool = false,
                           persistentDraftID: UUID? = nil, unknownDelivery: Bool = false) -> XCUIApplication {
        precondition(coldURL == nil || warmURL == nil, "Choose cold or warm fixture delivery")
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchArguments += [
            Identity.connectedDashboard, "https://conduit-ui-test.invalid",
            Identity.seededProfiles, "work,staging"
        ]
        if let coldURL {
            app.launchArguments += [Identity.coldWidgetURL, coldURL.absoluteString]
        } else if let warmURL {
            app.launchArguments += [Identity.coldWidgetURL, warmURL.absoluteString, Identity.widgetDeliveryMode, "warm"]
        }
        if holdReadiness {
            app.launchArguments.append(Identity.holdWidgetReadiness)
        }
        if let persistentDraftID {
            app.launchArguments += [Identity.persistentDraft, persistentDraftID.uuidString]
        }
        if unknownDelivery { app.launchArguments.append("-CONDUIT_UI_TEST_UNKNOWN_DELIVERY") }
        app.launch()
        return app
    }

    private func tree(_ app: XCUIApplication) -> String {
        "Widget launch outcome missing. Tree:\n\(app.debugDescription)"
    }
}
