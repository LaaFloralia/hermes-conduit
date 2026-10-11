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

    private func makeSignedOutAppState() -> AppState {
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
            dashboardRegistry: SavedDashboardRegistry(),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
    }
}
