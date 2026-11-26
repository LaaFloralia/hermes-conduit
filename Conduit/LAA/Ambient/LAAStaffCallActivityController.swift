#if LAA_BUILD
import Foundation
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import UserNotifications
#endif

/// The in-app call screen's state, as the call's Live Activity shows it
/// (HO-15). Pure, so the mapping is tested without ActivityKit.
enum LAAStaffCallActivityState {
    static func phase(of snapshot: LAAEmployeeCallSnapshot) -> LAAStaffCallPhase {
        switch snapshot.phase {
        case .connecting, .reconnecting: return .connecting
        case .ending, .ended, .failed: return .ended
        case .connected:
            if snapshot.muted { return .muted }
            if snapshot.speaking { return .speaking }
            if snapshot.activity == .thinking { return .thinking }
            return .listening
        }
    }

    static func content(of snapshot: LAAEmployeeCallSnapshot, now: Date = Date()) -> LAAStaffCallAttributes.ContentState {
        let phase = phase(of: snapshot)
        return LAAStaffCallAttributes.ContentState(phase: phase, connectedAt: snapshot.connectedAt,
                                                   endedAt: phase == .ended ? now : nil)
    }

    static func attributes(of context: LAAEmployeeCallContext) -> LAAStaffCallAttributes {
        LAAStaffCallAttributes(profile: context.profile, name: context.name,
                               link: context.conversationID.map { ConduitAppLink.session(id: $0, profile: context.profile).url })
    }

    /// Whether `next` is worth an ActivityKit update after `shown`: only the
    /// phase or the connection time matter; the end time never re-sends.
    static func differs(_ next: LAAStaffCallAttributes.ContentState, from shown: LAAStaffCallAttributes.ContentState?) -> Bool {
        guard let shown else { return true }
        return next.phase != shown.phase || next.connectedAt != shown.connectedAt
    }
}

/// Starts, updates and ends the call's Live Activity from the coordinator's
/// snapshot (`LAAEmployeeCallCoordinator.snapshot`). One call, one activity;
/// speaking and listening flip often, so updates are coalesced to one a
/// second. Nothing on the Mac, where ActivityKit is unavailable.
@MainActor
final class LAAStaffCallActivityController {
    static let shared = LAAStaffCallActivityController()

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private var activity: Activity<LAAStaffCallAttributes>?
    private var callID: UUID?
    private var shown: LAAStaffCallAttributes.ContentState?
    private var pending: LAAStaffCallAttributes.ContentState?
    private var flush: Task<Void, Never>?
    #endif

    func follow(_ snapshot: LAAEmployeeCallSnapshot?) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard LiveTurnActivities.isEnabled, !Self.inUnitTests else { return }
        guard let snapshot else { endCurrent(); return }
        if callID != snapshot.context.id {
            endCurrent()
            start(snapshot)
            return
        }
        let next = LAAStaffCallActivityState.content(of: snapshot)
        if next.callPhase == .ended { endCurrent(); return }
        guard LAAStaffCallActivityState.differs(next, from: pending ?? shown) else { return }
        pending = next
        guard flush == nil else { return }
        flush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.flush = nil
            guard let state = self.pending, let activity = self.activity else { return }
            self.pending = nil
            self.shown = state
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        #endif
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// The call tests drive the coordinator with a fake control; they must
    /// not leave cards on the simulator.
    private static let inUnitTests: Bool = {
        #if DEBUG
        return NSClassFromString("XCTestCase") != nil
        #else
        return false
        #endif
    }()

    private func start(_ snapshot: LAAEmployeeCallSnapshot) {
        let state = LAAStaffCallActivityState.content(of: snapshot)
        guard state.callPhase != .ended, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(attributes: LAAStaffCallActivityState.attributes(of: snapshot.context),
                                            content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            callID = snapshot.context.id
            shown = state
        } catch {
            activity = nil
            callID = nil
        }
    }

    private func endCurrent() {
        flush?.cancel()
        flush = nil
        pending = nil
        guard let activity else { callID = nil; shown = nil; return }
        let final = LAAStaffCallAttributes.ContentState(phase: .ended, connectedAt: shown?.connectedDate, endedAt: Date())
        self.activity = nil
        callID = nil
        shown = nil
        Task { await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate) }
    }
    #endif
}

#if DEBUG && os(iOS) && targetEnvironment(simulator)
/// `-LAA_AMBIENT_ACTIVITY_FIXTURE`: a Debug simulator launch starts one call
/// card (Morgan, speaking) and one turn card (Monet, thinking) from fixed
/// values, so the Lock Screen and Dynamic Island can be photographed
/// without a call, Hermes or the relay. It also asks for notification
/// permission, so a simulator `simctl push` shows its banner.
enum LAAAmbientActivityFixture {
    /// `-LAA_AMBIENT_ACTIVITY_FIXTURE call|turn`: Morgan's call while she
    /// speaks, or Monet's turn while she thinks; any other value starts both.
    static var mode: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-LAA_AMBIENT_ACTIVITY_FIXTURE") else { return nil }
        return arguments.indices.contains(index + 1) ? arguments[index + 1] : "both"
    }

    @MainActor static func startIfRequested() {
        guard let mode else { return }
        UNUserNotificationCenterBridge.requestAlerts()
        Task { @MainActor in
            for activity in Activity<LAAStaffCallAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
            for activity in Activity<HermesTurnAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
            // ActivityKit starts an activity only once the scene is active.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let now = Date()
            if mode != "turn" {
                let call = LAAStaffCallAttributes(profile: "laa-cfo", name: LAAStaff.cfo.name,
                                                  link: ConduitAppLink.session(id: "fixture-call", profile: "laa-cfo").url)
                _ = try? Activity.request(attributes: call,
                                          content: ActivityContent(state: .init(phase: .speaking, connectedAt: now.addingTimeInterval(-83)), staleDate: nil),
                                          pushType: nil)
            }
            if mode != "call" {
                let turn = HermesTurnAttributes(chatTitle: "週次の振り返り", startedAt: now.addingTimeInterval(-42), language: "ja",
                                                link: ConduitAppLink.session(id: "fixture-turn", profile: "laa-monet").url,
                                                sessionIDs: ["fixture-turn"], profileName: LAAStaff.monet.name)
                _ = try? Activity.request(attributes: turn,
                                          content: ActivityContent(state: .init(phase: .thinking, tools: 2, context: 34), staleDate: nil),
                                          pushType: nil)
            }
        }
    }
}

private enum UNUserNotificationCenterBridge {
    static func requestAlerts() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}
#endif
#endif
