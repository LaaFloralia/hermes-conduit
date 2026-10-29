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
    /// A server may not apply the requested voice; do not hide that fact.
    var voiceNote: String? = nil
}

/// The adapter follows the existing voice and CallKit path; it must report
/// confirmed state rather than pretending a control succeeded.
@MainActor
protocol LAAEmployeeCallControlling: AnyObject {
    var unavailableReason: String? { get }
    var onUpdate: ((LAAEmployeeCallSnapshot) -> Void)? { get set }
    func requiredConsent(for context: LAAEmployeeCallContext) -> LiveVoiceModeName?
    func grantConsent(_ mode: LiveVoiceModeName)
    func start(_ context: LAAEmployeeCallContext)
    func setMuted(_ muted: Bool)
    func setSpeaker(_ speaker: Bool)
    func end()
}

extension LAAEmployeeCallControlling {
    func requiredConsent(for context: LAAEmployeeCallContext) -> LiveVoiceModeName? { nil }
    func grantConsent(_ mode: LiveVoiceModeName) {}
}

struct LAAEmployeeCallConsent: Identifiable {
    let id = UUID()
    let mode: LiveVoiceModeName
}

@MainActor
final class LAAEmployeeCallCoordinator: ObservableObject {
    @Published private(set) var snapshot: LAAEmployeeCallSnapshot?
    @Published var isShowingCall = false
    @Published var consentRequest: LAAEmployeeCallConsent?
    private var pendingContext: LAAEmployeeCallContext?
    private var consentAccepted = false
    let control: LAAEmployeeCallControlling

    init(control: LAAEmployeeCallControlling) {
        self.control = control
        control.onUpdate = { [weak self] update in self?.receive(update) }
    }

    var unavailableReason: String? { control.unavailableReason }

    func bindVoiceControl(_ appState: AppState) {
        guard let voiceControl = control as? LAAEmployeeVoiceControl else { return }
        objectWillChange.send()
        voiceControl.bind(appState)
    }

    func start(profile: String, name: String, conversationID: String?) {
        guard control.unavailableReason == nil, snapshot == nil,
              consentRequest == nil, pendingContext == nil else { return }
        let context = LAAEmployeeCallContext(profile: profile, name: name, conversationID: conversationID)
        if let mode = control.requiredConsent(for: context) {
            pendingContext = context
            consentRequest = LAAEmployeeCallConsent(mode: mode)
            return
        }
        start(context)
    }

    func answerConsent(_ allowed: Bool) {
        guard let request = consentRequest, pendingContext != nil else { return }
        consentAccepted = allowed
        if allowed { control.grantConsent(request.mode) }
        consentRequest = nil
    }

    func consentDidDismiss() {
        let context = consentAccepted ? pendingContext : nil
        pendingContext = nil
        consentAccepted = false
        consentRequest = nil
        if let context { start(context) }
    }

    private func start(_ context: LAAEmployeeCallContext) {
        snapshot = LAAEmployeeCallSnapshot(context: context, phase: .connecting)
        isShowingCall = true
        control.start(context)
    }

    func receive(_ update: LAAEmployeeCallSnapshot) {
        // A late callback from a previous call must not replace the current one.
        guard let current = snapshot, update.context.id == current.context.id else { return }
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
            control.end()
            self.snapshot = nil
            isShowingCall = false
        } else {
            self.snapshot?.phase = .ending
            control.end()
        }
    }
}
#endif
