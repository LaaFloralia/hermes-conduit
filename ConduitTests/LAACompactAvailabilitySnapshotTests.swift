#if LAA_BUILD && DEBUG
import SwiftUI
import XCTest
@testable import Conduit

@MainActor
extension LAACompactChatSnapshotTests {
    private enum Screen { case artifacts, pendingCall, voiceSetup, phone, health, location, groupFileError, syncedPreferences, predictive }

    func testUnsupportedArtifactsAtCompactSizeInLightAndDark() throws {
        try capture(.artifacts, style: .light)
        try capture(.artifacts, style: .dark)
    }

    func testDefaultChatWhileCallIsPendingAtCompactSizeInLightAndDark() throws {
        try capture(.pendingCall, style: .light)
        try capture(.pendingCall, style: .dark)
    }

    func testVoiceSetupAtCompactSizeInLightAndDark() throws {
        try capture(.voiceSetup, style: .light)
        try capture(.voiceSetup, style: .dark)
    }

    func testSharingUnavailableAtCompactSizeInLightAndDark() throws {
        let screens: [Screen] = [.phone, .health, .location]
        for screen in screens {
            try capture(screen, style: .light)
            try capture(screen, style: .dark)
        }
    }

    func testGroupFileErrorAtCompactSizeInLightAndDark() throws {
        try capture(.groupFileError, style: .light)
        try capture(.groupFileError, style: .dark)
    }

    func testSettingsUnavailableAtCompactSizeInLightAndDark() throws {
        let screens: [Screen] = [.syncedPreferences, .predictive]
        for screen in screens {
            try capture(screen, style: .light)
            try capture(screen, style: .dark)
        }
    }

    private func capture(_ screen: Screen, style: UIUserInterfaceStyle) throws {
        let canvas = CGRect(x: 0, y: 0, width: 440, height: 956)
        let suite = "LAACompactAvailabilitySnapshotTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let fixture = LAABackgroundFixture(chatFixtureOverride: "rich", defaultsSuiteName: suite)
        let state = fixture.state
        state.themePreference = style == .dark ? .dark : .light
        let bridge = LAABridgeSession(statusForTesting: .paired)
        let calls = LAAEmployeeCallCoordinator(control: CompactAvailabilityCallControl())
        let content: AnyView
        let name: String
        switch screen {
        case .artifacts:
            XCTAssertFalse(state.supportsArtifacts)
            content = AnyView(NavigationStack {
                ChatArtifactsContent(sessionIDs: ["fixture-chat"], tab: .constant(.made)) { _ in }
            })
            name = "unsupported-artifacts"
        case .pendingCall:
            state.setActiveProfileForTesting("default")
            state.laaEmployeeGPTLivePlan = state.laaEmployeeCallPlan(profile: "laa-cto")
            XCTAssertNotNil(state.laaEmployeeGPTLivePlan)
            XCTAssertEqual(state.conversationIdentityProfile, "default")
            XCTAssertEqual(state.phoneVoiceUnavailableReason, LAACopy.otherCallInProgress)
            content = AnyView(NavigationStack { V2ConversationScreen() })
            name = "default-call-pending"
        case .voiceSetup:
            content = AnyView(LiveVoiceSetupSheet(mode: .gpt))
            name = "voice-setup"
        case .phone:
            let engine = PhoneSyncEngine(calendarSource: EventKitPhoneSource(), statusSource: DevicePhoneStatusSource(),
                                         defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
            XCTAssertFalse(engine.preferences.isOn)
            content = AnyView(NavigationStack { PhoneSettingsPage(engine: engine) })
            name = "unsupported-phone-sharing"
        case .health:
            state.healthSyncPreferences = HealthSyncPreferences()
            let engine = HealthSyncEngine(source: CompactHealthSource())
            content = AnyView(NavigationStack { HealthSettingsPage(engine: engine) })
            name = "unsupported-health-sharing"
        case .location:
            let controller = LocationSharingController.shared
            XCTAssertFalse(controller.settings.isOn)
            content = AnyView(NavigationStack { LocationSettingsPage(controller: controller, engine: controller.engine) })
            name = "unsupported-location-sharing"
        case .groupFileError:
            let room = GroupRoom(roomID: "fixture-room", name: "Team", members: [],
                                 authorityGatewayID: "fixture-gateway", authorityEpoch: 1, revision: 1,
                                 createdAt: 0, updatedAt: 0, disbandedAt: nil, latestSeq: 0)
            state.setActiveRoomSurfaceForTesting(.init(dashboardID: UUID(), room: room))
            state.errorMessage = LAACopy.groupFilesUnavailable
            content = AnyView(NavigationStack { V2ConversationScreen() })
            name = "group-file-error"
        case .syncedPreferences:
            XCTAssertFalse(state.supportsSyncedPreferences)
            content = AnyView(NavigationStack { SyncedPreferencesSettingsDetail(controller: state.syncedPreferences) })
            name = "unsupported-settings-sync"
        case .predictive:
            XCTAssertFalse(state.predictiveIsServed)
            content = AnyView(NavigationStack { PredictiveSettingsPage() })
            name = "unsupported-predictive"
        }
        let host = UIHostingController(rootView: content
            .environmentObject(state).environmentObject(bridge).environmentObject(calls)
            .preferredColorScheme(style == .dark ? .dark : .light))
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let insets = previous?.safeAreaInsets ?? .zero
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: canvas.width + insets.left + insets.right, height: canvas.height)
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.verticalSizeClass = .regular
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        host.view.layoutIfNeeded()
        if case .groupFileError = screen {
            XCTAssertEqual(state.errorMessage, LAACopy.groupFilesUnavailable)
        }
        XCTAssertEqual(window.bounds.width - host.view.safeAreaInsets.left - host.view.safeAreaInsets.right,
                       canvas.width, accuracy: 0.5)
        XCTAssertEqual(window.bounds.height, canvas.height, accuracy: 0.5)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let viewport = CGRect(x: host.view.safeAreaInsets.left * format.scale, y: 0,
                              width: canvas.width * format.scale, height: canvas.height * format.scale)
        let cropped = try XCTUnwrap(rendered.cgImage?.cropping(to: viewport))
        XCTAssertEqual(cropped.width, 1320)
        XCTAssertEqual(cropped.height, 2868)
        let image = UIImage(cgImage: cropped, scale: format.scale, orientation: .up)
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(name)-440x956-\(style == .dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private final class CompactHealthSource: HealthDataSource {
    var isAvailable: Bool { true }
    func requestAuthorization(for categories: Set<HealthCategory>, detailed: Set<HealthCategory>) async throws {}
    func buckets(_ metric: HealthMetric, grain: HealthGrain, from: Date, to: Date, calendar: Calendar) async throws -> [HealthBucket] { [] }
    func sleepSegments(from: Date, to: Date) async throws -> [HealthSleepSegment] { [] }
    func changes(_ stream: HealthEventStream, since: Date, anchor: Data?, limit: Int) async throws -> HealthEventChanges {
        HealthEventChanges(added: [], deleted: [], anchor: nil, more: false)
    }
    func earliestDate() -> Date { .distantPast }
    func observe(_ categories: Set<HealthCategory>, onChange: @escaping (_ done: @escaping () -> Void) -> Void) async {}
    func stopObserving() async {}
}

@MainActor
private final class CompactAvailabilityCallControl: LAAEmployeeCallControlling {
    var unavailableReason: String? { nil }
    var onUpdate: ((LAAEmployeeCallSnapshot) -> Void)?
    func start(_ context: LAAEmployeeCallContext) {}
    func setMuted(_ muted: Bool) {}
    func setSpeaker(_ speaker: Bool) {}
    func end() {}
}
#endif
