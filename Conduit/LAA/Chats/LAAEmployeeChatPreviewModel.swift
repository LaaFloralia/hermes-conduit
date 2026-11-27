#if LAA_BUILD
import Foundation
import Combine
import os
/// Owns only a read-only preview. Live connection/profile state is never
/// changed just to show a cached conversation for another employee.
@MainActor
final class LAAEmployeeChatPreview: ObservableObject {
    @Published private(set) var presentation: OfflineChatPresentation?
    @Published private(set) var failure: String?
    private(set) var recoversAfterTransportLoss = false
    @Published var queuedSend: PendingComposerSend?
    private(set) var workspace: WidgetWorkspaceID?
    private var preferredSessionID: String?
    var queueTargetSessionID: String? {
        guard let workspace else { return nil }
        if let presentation, presentation.dashboardID == workspace.dashboardID, presentation.profile == workspace.profile,
           let cachedID = presentation.composerSessionID { return cachedID }
        return preferredSessionID
    }

    func canQueue(_ text: String, isComposing: Bool) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = queueTargetSessionID, !target.isEmpty,
              target != ComposerDraftKey.newConversationSessionID else { return false }
        return (failure == nil || recoversAfterTransportLoss) && queuedSend == nil && !isComposing && !text.isEmpty
            && AppState.parseSlashCommand(text) == nil
    }
    private var generation = 0
    private var read: Task<Void, Never>?
    /// This open's phase timings (D-25); nil between opens.
    private(set) var metrics: LAAEmployeeOpenMetrics?
    /// How the next open is counted (AppState sets it from the scene).
    var nextScenario: LAAEmployeeOpenMetrics.Scenario = .cold
    var networkClass: @MainActor () -> LAAEmployeeOpenMetrics.NetworkClass = { .wifi }

    /// The rows the opening screen draws, exactly: the owner's and the
    /// employee's turns with something to read. Its empty check (the 132 pt
    /// avatar) uses the same list, so system and tool rows can never hide
    /// the avatar and leave the body blank (D-25: a tool-heavy Monet tail).
    nonisolated static func renderable(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.filter { message in
            switch message.role {
            case .user, .assistant, .partial:
                return LAAChatVisibility.shows(message)
                    && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return false
            }
        }
    }

    /// Copies read ahead for the staff, so a tap shows one at once (D-25).
    /// Each is replaced by the disk read every open still runs.
    private(set) static var warmed: [WidgetWorkspaceID: OfflineChatPresentation] = [:]
    private static var warming: Task<Void, Never>?

    /// Reads every seated employee's copy for `dashboardID` off the main
    /// actor (launch, and each return to the app).
    static func prewarm(dashboardID: UUID, directory: URL,
                        preferredSessionID: @escaping (String) -> String? = { _ in nil }) {
        let profiles = LAAStaff.allCases.map { "laa-\($0.rawValue)" }
        let preferred = Dictionary(uniqueKeysWithValues: profiles.map { ($0, preferredSessionID($0)) })
        warming?.cancel()
        warming = Task {
            let loaded = await Task.detached(priority: .utility) {
                var copies: [WidgetWorkspaceID: OfflineChatPresentation] = [:]
                for profile in profiles {
                    if Task.isCancelled { break }
                    let workspace = WidgetWorkspaceID(dashboardID: dashboardID, profile: profile)
                    if let copy = LAAEmployeeChatPreview.load(workspace: workspace, directory: directory,
                                       preferredSessionID: preferred[profile] ?? nil) {
                        copies[workspace] = copy
                    }
                }
                return copies
            }.value
            guard !Task.isCancelled else { return }
            warmed = warmed.filter { $0.key.dashboardID != dashboardID }.merging(loaded) { $1 }
        }
    }

    static func forgetWarmed() {
        warming?.cancel()
        warming = nil
        warmed = [:]
    }

    func noteComposerEditable() {
        metrics?.mark(.composerEditable)
    }

    /// A connection step on the way (the connection timeline's labels).
    func noteConnectionStep(_ label: String) {
        guard let phase = LAAEmployeeOpenMetrics.phase(forConnectionStep: label) else { return }
        metrics?.mark(phase)
    }

    func noteModelInfo() {
        metrics?.mark(.modelInfo)
    }

    private func finishMetrics(_ outcome: WidgetLaunchOutcome?) {
        guard var metrics, !metrics.isFinished else { return }
        let name: String
        switch outcome {
        case .handled: name = "handled"
        case .failed: name = "failed"
        case .superseded: name = "superseded"
        case .deferred: name = "deferred"
        case nil: name = "ended"
        }
        metrics.finish(outcome: name)
        self.metrics = metrics
        LAAEmployeeOpenMetrics.latest = metrics
        LAAEmployeeOpenMetrics.log.notice("\(metrics.summary, privacy: .public)")
        onMetricsFinished?(metrics)
    }

    var onMetricsFinished: (@MainActor (LAAEmployeeOpenMetrics) -> Void)?
    private static let log = OSLog(subsystem: "com.laa.performance", category: .pointsOfInterest)
    private var interval: OSSignpostID?

    // A cold ticket, profile catalog and native history resume share the
    // same bounded launch budget; eight seconds cancelled healthy 5G opens.
    static let timeout: Duration = WidgetLaunchCoordinator.launchTimeout
    static let unavailable = "Macの会話サービスから応答がありません。接続を確認して再試行してください。"

    func begin(workspace: WidgetWorkspaceID, directory: URL, preferredSessionID: String?) {
        if self.workspace != workspace { clear() }
        self.workspace = workspace
        self.preferredSessionID = preferredSessionID
        recoversAfterTransportLoss = false
        failure = nil
        if interval == nil {
            let interval = OSSignpostID(log: Self.log)
            self.interval = interval
            os_signpost(.begin, log: Self.log, name: "EmployeeConversationOpen", signpostID: interval)
            metrics = LAAEmployeeOpenMetrics(scenario: nextScenario, networkClass: networkClass())
            nextScenario = .switch
        }
        // Retry the transport without flashing away this employee's copy or
        // moving a reserved send to the new-chat draft while disk is read.
        guard presentation == nil, read == nil else { return }
        // A copy read ahead shows in this same frame; the read below still
        // replaces it with the newest one on disk.
        if let warm = Self.warmed[workspace],
           preferredSessionID == nil || warm.composerSessionID == preferredSessionID {
            presentation = warm
            metrics?.mark(.cachedTranscript)
            if let interval {
                os_signpost(.event, log: Self.log, name: "EmployeeCachedTranscriptReady", signpostID: interval)
            }
        }
        let generation = generation
        read = Task { [weak self] in
            let presentation = await Task.detached(priority: .userInitiated) {
                Self.load(workspace: workspace, directory: directory, preferredSessionID: preferredSessionID)
            }.value
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.read = nil
            if let presentation {
                let first = self.presentation == nil
                if self.presentation != presentation { self.presentation = presentation }
                Self.warmed[workspace] = presentation
                if first {
                    self.metrics?.mark(.cachedTranscript)
                    if let interval = self.interval {
                        os_signpost(.event, log: Self.log, name: "EmployeeCachedTranscriptReady", signpostID: interval)
                    }
                }
            }
        }
    }

    func noteLiveReady() {
        metrics?.mark(.liveReady)
        if let interval {
            os_signpost(.event, log: Self.log, name: "EmployeeLiveChatReady", signpostID: interval)
        }
    }

    func finish(_ outcome: WidgetLaunchOutcome?, recoversAfterTransportLoss: Bool = false) {
        finishMetrics(outcome)
        if let interval {
            os_signpost(.end, log: Self.log, name: "EmployeeConversationOpen", signpostID: interval)
            self.interval = nil
        }
        if case .failed(let reason) = outcome {
            // Keep the employee and their copy on screen. Clearing it would
            // expose the previous employee's still-connected conversation.
            self.recoversAfterTransportLoss = recoversAfterTransportLoss
            failure = reason
        } else {
            clear()
        }
    }

    func clear() {
        finishMetrics(nil)
        metrics = nil
        if let interval {
            os_signpost(.end, log: Self.log, name: "EmployeeConversationOpen", signpostID: interval)
            self.interval = nil
        }
        generation &+= 1
        read?.cancel()
        read = nil
        workspace = nil
        preferredSessionID = nil
        presentation = nil
        recoversAfterTransportLoss = false
        failure = nil
    }

    nonisolated static func load(workspace: WidgetWorkspaceID, directory: URL,
                                 preferredSessionID: String?) -> OfflineChatPresentation? {
        let log = OSLog(subsystem: "com.laa.performance", category: .pointsOfInterest)
        let signpost = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "EmployeeCachedTranscript", signpostID: signpost)
        defer { os_signpost(.end, log: log, name: "EmployeeCachedTranscript", signpostID: signpost) }
        let store = OfflineChatCacheStore(directory: directory)
        guard let snapshot = store.load(dashboardID: workspace.dashboardID, profile: workspace.profile) else { return nil }
        // A dashboard employee chat must not substitute a bot/cron transcript.
        let chatIDs = Set(snapshot.sessions.filter { $0.source == .chat }.map(\.id))
        let candidates = [preferredSessionID, snapshot.lastSessionID].compactMap { $0 }
            + snapshot.transcripts.map(\.sessionID)
        guard let id = candidates.first(where: { chatIDs.contains($0) && snapshot.transcript(for: $0) != nil }),
              let transcript = store.loadTranscript(id, dashboardID: workspace.dashboardID, profile: workspace.profile) else { return nil }
        return TranscriptPerf.withoutRecording {
            OfflineChatPresentation(dashboardID: workspace.dashboardID, profile: workspace.profile,
                                    snapshot: snapshot, displayedTranscript: transcript)
        }
    }
}
#endif
