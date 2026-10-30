#if LAA_BUILD
import Foundation

/// Captured before CallKit starts, so a chat's workspace cannot change the
/// employee, voice, or billing selected for the call.
struct LAAEmployeeGPTLivePlan: Equatable {
    let id: UUID = UUID()
    let profile: String
    let voice: String
    let dashboardID: UUID?
    let engine: VoiceCallEngine = .gptLive
    let billing: GPTLiveBilling = .subscription

    static func make(profile: String, savedVoice: String?, dashboardID: UUID? = nil) -> Self? {
        guard let staff = LAAStaff(profile: profile) else { return nil }
        let voices = Set(GPTLiveVoice.all.map(\.name))
        let voice = savedVoice.flatMap { voices.contains($0) ? $0 : nil } ?? staff.defaultGPTLiveVoice
        return Self(profile: profile, voice: voice, dashboardID: dashboardID)
    }
}

extension LAAStaff {
    /// ChatGPT subscription voices, chosen independently for each employee.
    var defaultGPTLiveVoice: String {
        switch self {
        case .ciel: return "vale"
        case .argus: return "ember"
        case .cfo: return "arbor"
        case .cio: return "cove"
        case .cmo: return "maple"
        case .cos: return "spruce"
        case .cso: return "sol"
        case .cto: return "juniper"
        }
    }
}

@MainActor
extension AppState {
    var laaGPTLiveProfile: String { laaEmployeeGPTLivePlan?.profile ?? activeProfile }

    var laaGPTLiveToolScope: VoiceHostToolScope? {
        laaEmployeeGPTLivePlan.map { VoiceHostToolScope(dashboardID: $0.dashboardID, profile: $0.profile) }
    }

    /// Retry a transient host failure once, while the same call still owns it.
    func laaEmployeePersonality(_ context: GeminiLiveTokenClient, plan: LAAEmployeeGPTLivePlan) async -> GeminiLiveTokenClient.EmployeePersonality {
        let first = await context.employeePersonality()
        guard first == .unavailable, !Task.isCancelled, laaEmployeeGPTLivePlan == plan else { return first }
        return await context.employeePersonality()
    }

    func laaVoiceResumeEngine(profile: String) -> VoiceCallEngine? {
        laaEmployeeGPTLivePlan?.engine ?? configuredLiveVoiceEngine(profile: profile)
    }

    /// Both requests use the same captured employee identity, including when
    /// the open Bot Chat belongs to a different workspace profile.
    func laaGPTLiveClient(request: @escaping GPTLiveClient.Request) -> GPTLiveClient {
        GPTLiveClient(profile: { [weak self] in
            self?.laaEmployeeGPTLivePlan?.profile ?? self?.activeProfile ?? "default"
        }, billing: { [weak self] in
            self?.gptLiveCallBilling ?? .subscription
        }, request: request)
    }

    func laaGPTLiveHostContext(request: @escaping GeminiLiveTokenClient.Request) -> GeminiLiveTokenClient {
        GeminiLiveTokenClient(profile: { [weak self] in
            self?.laaEmployeeGPTLivePlan?.profile ?? self?.activeProfile ?? "default"
        }, request: request)
    }
}
#endif
