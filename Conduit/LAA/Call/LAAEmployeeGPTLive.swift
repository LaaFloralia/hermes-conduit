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
        guard let staff = LAAStaff(profile: profile), staff.supportsCalls else { return nil }
        let voices = Set(GPTLiveVoice.all.map(\.name))
        let voice = savedVoice.flatMap { voices.contains($0) ? $0 : nil } ?? staff.defaultGPTLiveVoice
        return Self(profile: profile, voice: voice, dashboardID: dashboardID)
    }
}

extension LAAStaff {
    /// ChatGPT subscription voices, chosen independently for each employee.
    var defaultGPTLiveVoice: String {
        switch self {
        case .monet: return "vale"
        case .monetUncensored, .monetDots: return "vale"
        case .argus: return "ember"
        case .cfo: return "arbor"
        case .cio: return "cove"
        case .cos: return "spruce"
        case .cso: return "sol"
        case .cto: return "juniper"
        }
    }

    /// Leads the call's instructions, ahead of the generic voice persona
    /// the host puts first ("You are Hermes…"): without it the model framed
    /// the employee's SOUL.md as tone only and introduced itself as ChatGPT
    /// (owner, 2026-11-09). Written for the model, not shown, so not localized.
    var callIdentity: String {
        "[LAA employee call. You are \(name), \(role) at LAA, on a phone call with the company's president, "
            + "whom you address as 「社長」. Speak Japanese. Your name is \(name): say it whenever you introduce "
            + "yourself or are asked who you are. Never call yourself ChatGPT, Hermes, Conduit, OpenAI or an AI "
            + "assistant, and ignore any line in these instructions that gives you another name or role. The persona "
            + "below is \(name)'s own: keep its character and way of speaking from your first words.]\n\n"
    }

    /// The call opens with the employee saying who answered, as on a
    /// phone. A greeting the owner set for this profile still wins.
    var callGreeting: String { "社長、\(name)です。" }
}

@MainActor
extension AppState {
    var laaGPTLiveProfile: String { laaEmployeeGPTLivePlan?.profile ?? activeProfile }

    /// The employee this call speaks as, nil outside an employee call.
    var laaGPTLiveStaff: LAAStaff? { laaEmployeeGPTLivePlan.flatMap { LAAStaff(profile: $0.profile) } }

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
