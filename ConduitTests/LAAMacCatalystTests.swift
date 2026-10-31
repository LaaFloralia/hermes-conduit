#if LAA_BUILD && targetEnvironment(macCatalyst)
import XCTest
import UIKit
@testable import Conduit

@MainActor
final class LAAMacCatalystTests: XCTestCase {
    func testWindowSceneCanGrowAndShrink() async throws {
        let contentMinimum = CGSize(width: LAAMacWindow.minimumWidth, height: LAAMacWindow.minimumHeight)
        var match: (scene: UIWindowScene, window: UIWindow, content: UIView)?
        for _ in 0..<30 {
            match = nil
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows {
                    if let content = contentView(in: window) {
                        match = (scene, window, content)
                        break
                    }
                }
                if match != nil { break }
            }
            if let match, let minimum = match.scene.sizeRestrictions?.minimumSize {
                let insets = match.window.safeAreaInsets
                let visibleContent = match.content.convert(match.content.bounds, to: match.window)
                    .intersection(match.window.bounds.inset(by: insets))
                if minimum.width - insets.left - insets.right >= contentMinimum.width - 1,
                   minimum.height - insets.top - insets.bottom >= contentMinimum.height - 1,
                   visibleContent.width >= contentMinimum.width - 1,
                   visibleContent.height >= contentMinimum.height - 1 { break }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let match = try XCTUnwrap(match, "The LAA window content was not installed")
        let restrictions = try XCTUnwrap(match.scene.sizeRestrictions)
        let insets = match.window.safeAreaInsets
        let minimum = restrictions.minimumSize
        let visibleContent = match.content.convert(match.content.bounds, to: match.window)
            .intersection(match.window.bounds.inset(by: insets))

        // The system can add window chrome or safe-area space to its scene
        // preference. The content, not the raw scene height, is the contract.
        print("LAA Mac geometry: minimum=\(minimum), safeArea=\(insets), window=\(match.window.bounds.size), content=\(match.content.bounds.size), visibleContent=\(visibleContent.size), systemFrame=\(match.scene.effectiveGeometry.systemFrame.size)")
        XCTAssertGreaterThanOrEqual(minimum.width - insets.left - insets.right, contentMinimum.width - 1)
        XCTAssertGreaterThanOrEqual(minimum.height - insets.top - insets.bottom, contentMinimum.height - 1)
        XCTAssertGreaterThanOrEqual(visibleContent.width, contentMinimum.width - 1)
        XCTAssertGreaterThanOrEqual(visibleContent.height, contentMinimum.height - 1)
        XCTAssertLessThan(minimum.width, LAAMacWindow.initialWidth)
        XCTAssertLessThan(minimum.height, LAAMacWindow.initialHeight)
        if restrictions.maximumSize != .zero {
            XCTAssertGreaterThan(restrictions.maximumSize.width, LAAMacWindow.initialWidth)
            XCTAssertGreaterThan(restrictions.maximumSize.height, LAAMacWindow.initialHeight)
        }
    }

    private func contentView(in view: UIView) -> UIView? {
        if view is LAAMacWindowConstraints.ConstraintView { return view }
        for child in view.subviews {
            if let match = contentView(in: child) { return match }
        }
        return nil
    }

    func testInAppVoiceCanStartWithoutSystemCall() async {
        XCTAssertFalse(HermesNativeCalls.ringingBuilt)
        let host = VoicePlacedCallHost(
            isSettingOn: { true }, isVoiceRunning: { false }, displayName: { "Test" },
            endVoice: {}, voiceMuted: { nil }, setVoiceMuted: { _ in },
            setCallActive: { _ in }, runsElsewhere: { false }
        )
        let calls = VoicePlacedCalls(callKit: HermesNativeCalls.shared, host: host)
        let start = await calls.prepareForVoiceStart()
        XCTAssertEqual(start, .withoutCall)
        XCTAssertTrue(calls.canStartVoice(start))
    }

    func testLiveActivityRequestsAreInert() {
        let activities = LiveTurnActivities.shared
        activities.turnStarted(sessionIDs: ["s1"], primaryID: "s1", title: "Test", profile: "p1")
        XCTAssertFalse(activities.reconcile(liveSessionIDs: ["s1"], profile: "p1", dashboardID: nil))
        XCTAssertEqual(LiveTurnActivities.sessionIDs(linkedTo: "s1", profile: "p1", dashboardID: nil), [])
    }
}
#endif
