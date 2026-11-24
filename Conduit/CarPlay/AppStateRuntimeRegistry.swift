//
//  AppStateRuntimeRegistry.swift
//  Conduit
//
//  Process-wide home of the single AppState instance.
//
//  SwiftUI's `@StateObject` evaluates its factory lazily when the foreground
//  scene first renders, but a CarPlay-first launch can connect the CarPlay
//  scene before any phone scene exists. Both surfaces therefore resolve the
//  AppState through this MainActor registry: whoever needs it first creates
//  it, and the other surface adopts the exact same instance. The registry is
//  a reference/lifecycle seam only — it owns no business logic.
//

import Foundation

@MainActor
final class AppStateRuntimeRegistry {
    static let shared = AppStateRuntimeRegistry()

    private var stored: AppState?

    /// The process-wide AppState, created on first access. AppState's own
    /// initializer performs the authoritative cold-launch bootstrap (saved
    /// connection restore), so a CarPlay-first launch establishes connection
    /// readiness without waiting for any phone view to run.
    var appState: AppState {
        if let stored { return stored }
        let created: AppState
#if DEBUG
        if let fixture = WidgetLaunchUITestFixture.createAppStateIfEnabled() {
            created = fixture
        } else if ProcessInfo.processInfo.environment["CONDUIT_UITEST"] == "1",
                  ProcessInfo.processInfo.arguments.contains("-CONDUIT_UI_TEST_FRESH_LOGIN") {
            // Login and Connection Setup exercise first-run behavior even if
            // hosted tests have left a dashboard roster in simulator Keychain.
            // Substitute an in-memory empty registry; never delete that roster.
            created = AppState(loadSavedConnection: false, dashboardRegistry: SavedDashboardRegistry())
        } else {
            created = AppState()
        }
#else
        created = AppState()
#endif
        stored = created
        return created
    }

    /// The AppState if one was created, without creating it: a call
    /// reported from a VoIP push checks it before anything else runs.
    var existing: AppState? { stored }

    internal init() {}

    /// Test isolation only.
    internal func resetForTesting() {
        stored = nil
    }
}
