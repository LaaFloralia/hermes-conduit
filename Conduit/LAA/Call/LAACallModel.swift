#if LAA_BUILD
import Foundation
import Combine

struct LAAEmployeeCallContext: Equatable {
    let id: UUID
    let profile: String
    let name: String
    let conversationID: String?

    init(id: UUID = UUID(), profile: String, name: String, conversationID: String?) {
        self.id = id
        self.profile = profile
        self.name = name
        self.conversationID = conversationID
    }
}

enum LAAEmployeeCallPhase: Equatable {
    case connecting, connected, ending, ended, failed(String)

    var isOngoing: Bool {
        switch self {
        case .connecting, .connected, .ending: return true
        case .ended, .failed: return false
        }
    }
}

struct LAAEmployeeCallSnapshot: Equatable {
    let context: LAAEmployeeCallContext
    var phase: LAAEmployeeCallPhase
    var connectedAt: Date? = nil
    var muted = false
    var speaker = false
    /// Native calls use the system route picker instead of the app's speaker toggle.
    var usesSystemRoutePicker = false
    /// nil means the active voice engine has no measured level available.
    var audioLevel: Float? = nil
}

/// The adapter follows the existing voice and CallKit path; it must report
/// confirmed state rather than pretending a control succeeded.
@MainActor
protocol LAAEmployeeCallControlling: AnyObject {
    var unavailableReason: String? { get }
    var onUpdate: ((LAAEmployeeCallSnapshot) -> Void)? { get set }
    func start(_ context: LAAEmployeeCallContext)
    func setMuted(_ muted: Bool)
    func setSpeaker(_ speaker: Bool)
    func end()
}

/// Until the outgoing-call branch is integrated the entry point is disabled.
@MainActor
final class LAAUnavailableCallControl: LAAEmployeeCallControlling {
    var unavailableReason: String? { "通話機能の準備中です" }
    var onUpdate: ((LAAEmployeeCallSnapshot) -> Void)?
    func start(_ context: LAAEmployeeCallContext) {}
    func setMuted(_ muted: Bool) {}
    func setSpeaker(_ speaker: Bool) {}
    func end() {}
}

@MainActor
final class LAAEmployeeCallCoordinator: ObservableObject {
    @Published private(set) var snapshot: LAAEmployeeCallSnapshot?
    @Published var isShowingCall = false
    let control: LAAEmployeeCallControlling

    init(control: LAAEmployeeCallControlling) {
        self.control = control
        control.onUpdate = { [weak self] update in self?.receive(update) }
    }

    var unavailableReason: String? { control.unavailableReason }

    func start(profile: String, name: String, conversationID: String?) {
        guard control.unavailableReason == nil, snapshot?.phase.isOngoing != true else { return }
        let context = LAAEmployeeCallContext(profile: profile, name: name, conversationID: conversationID)
        snapshot = LAAEmployeeCallSnapshot(context: context, phase: .connecting)
        isShowingCall = true
        control.start(context)
    }

    func receive(_ update: LAAEmployeeCallSnapshot) {
        // A late callback from a previous call must not replace the current one.
        guard let current = snapshot, update.context == current.context else { return }
        // Once ending starts, a delayed connection or level callback must not
        // resurrect the call. The adapter can still report end or failure.
        if case .ending = current.phase {
            switch update.phase {
            case .ending, .ended, .failed: break
            case .connecting, .connected: return
            }
        }
        if case .failed = current.phase {
            switch update.phase {
            case .ended, .failed: break
            case .connecting, .connected, .ending: return
            }
        }
        if case .ended = update.phase {
            snapshot = nil
            isShowingCall = false
        } else {
            snapshot = update
        }
    }

    func showChat() { isShowingCall = false }
    func showCall() { if snapshot != nil { isShowingCall = true } }
    func toggleMute() { if let snapshot { control.setMuted(!snapshot.muted) } }
    func toggleSpeaker() { if let snapshot { control.setSpeaker(!snapshot.speaker) } }
    func end() {
        guard let snapshot else { return }
        if case .ending = snapshot.phase { return }
        if case .failed = snapshot.phase {
            self.snapshot = nil
            isShowingCall = false
        } else {
            self.snapshot?.phase = .ending
            control.end()
        }
    }
}
#endif
