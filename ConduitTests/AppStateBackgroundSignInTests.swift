import XCTest
@testable import Conduit

/// A sign-in that came up while Conduit ran in the background (a call from
/// Hermes, the Apple Watch or CarPlay launched it) runs the saved sign-in
/// again once Conduit is on screen, instead of leaving the user signed out.
/// An extension of an existing class, so the CI test plan gains no class.
extension AppStateForegroundLifecycleTests {
    func testSignInRaisedInBackgroundRetriesSavedSignInOnScreen() {
        let appState = makeSignedOutAppState()
        var inBackground = true
        appState.appRunsInBackground = { inBackground }

        appState.showLogin = true
        XCTAssertTrue(appState.signInWaitsForForeground)
        appState.pendingLoginFailure = .notice(title: "Sign-in didn’t complete", message: "background")

        inBackground = false
        appState.handleScenePhase(.background)
        appState.handleScenePhase(.active)

        // The retry ran: the background attempt's failure is gone, and with
        // nothing saved the sign-in stays up without waiting again.
        XCTAssertNil(appState.pendingLoginFailure)
        XCTAssertTrue(appState.showLogin)
        XCTAssertFalse(appState.signInWaitsForForeground)
    }

    func testSignInRaisedOnScreenDoesNotRetry() {
        let appState = makeSignedOutAppState()
        appState.appRunsInBackground = { false }

        appState.showLogin = true
        XCTAssertFalse(appState.signInWaitsForForeground)
        let failure = ConnectionFailurePresentation.notice(title: "Sign-in didn’t complete", message: "on screen")
        appState.pendingLoginFailure = failure

        appState.handleScenePhase(.background)
        appState.handleScenePhase(.active)

        XCTAssertEqual(appState.pendingLoginFailure, failure)
    }

    func testSignedInAgainInBackgroundStopsWaiting() {
        let appState = makeSignedOutAppState()
        appState.appRunsInBackground = { true }

        appState.showLogin = true
        XCTAssertTrue(appState.signInWaitsForForeground)
        appState.showLogin = false
        XCTAssertFalse(appState.signInWaitsForForeground)
    }

    /// A call from Hermes that wakes a closed Conduit, phone unlocked, Face
    /// ID dashboard: Face ID can't show, so the saved session connects
    /// instead of the sign-in screen (Eric's choice, 2026-10-11).
    func testFaceIDDashboardInBackgroundConnectsWithSavedSession() async throws {
        let (appState, dashboard) = installFaceIDDashboard(savedTicket: "saved-ticket")
        appState.appRunsInBackground = { true }

        appState.loadSavedConnection()
        try await waitUntil { appState.connection != nil || appState.signInWaitsForForeground }

        XCTAssertEqual(appState.connection, HermesConnection(baseUrl: dashboard.normalizedURL, ticket: "saved-ticket"))
        XCTAssertFalse(appState.showLogin)
        XCTAssertFalse(appState.signInWaitsForForeground)
    }

    /// No saved session to fall back on: sign-in waits for the screen.
    func testFaceIDDashboardInBackgroundWithoutSavedSessionWaitsForTheScreen() async throws {
        let (appState, _) = installFaceIDDashboard(savedTicket: nil)
        appState.appRunsInBackground = { true }

        appState.loadSavedConnection()
        try await waitUntil { appState.connection != nil || appState.signInWaitsForForeground }

        XCTAssertNil(appState.connection)
        XCTAssertTrue(appState.showLogin)
        XCTAssertTrue(appState.signInWaitsForForeground)
    }

    /// On screen, a refused Face ID still goes to sign-in: the saved session
    /// never stands in for it there.
    func testFaceIDRefusedOnScreenStillGoesToSignIn() async throws {
        let (appState, _) = installFaceIDDashboard(savedTicket: "saved-ticket")
        appState.appRunsInBackground = { false }
        var unlockAsked = false
        appState.unlockWithFaceID = {
            unlockAsked = true
            return false
        }

        appState.loadSavedConnection()
        try await waitUntil { unlockAsked }
        await Task.yield()

        XCTAssertNil(appState.connection)
        XCTAssertTrue(appState.showLogin)
        XCTAssertFalse(appState.signInWaitsForForeground)
    }

    private func installFaceIDDashboard(savedTicket: String?) -> (AppState, SavedDashboard) {
        // An unsigned simulator test host can't write the system keychain.
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        // Loopback port 1: nothing listens, so no request leaves the host.
        let dashboard = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: dashboard.normalizedURL, username: "hermes", password: "secret", requiresFaceID: true),
            dashboardID: dashboard.id
        )
        if let savedTicket {
            KeychainHelper.saveConnection(
                HermesConnection(baseUrl: dashboard.normalizedURL, ticket: savedTicket),
                dashboardID: dashboard.id
            )
        }
        let appState = makeSignedOutAppState(
            registry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard])
        )
        appState.unlockWithFaceID = { false }
        return (appState, dashboard)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the restore")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeSignedOutAppState(
        registry: SavedDashboardRegistry = SavedDashboardRegistry()
    ) -> AppState {
        let suite = "AppStateBackgroundSignInTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: registry,
            clearSessionPresentationCache: {},
            // A failed connect would retry for real: keep the retry inert.
            reconnectScheduler: { _, _ in {} },
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
    }
}
