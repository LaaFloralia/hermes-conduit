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
        }
        // Retry the transport without flashing away this employee's copy or
        // moving a reserved send to the new-chat draft while disk is read.
        guard presentation == nil, read == nil else { return }
        let generation = generation
        read = Task { [weak self] in
            let presentation = await Task.detached(priority: .userInitiated) {
                Self.load(workspace: workspace, directory: directory, preferredSessionID: preferredSessionID)
            }.value
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.read = nil
            if let presentation {
                self.presentation = presentation
                if let interval = self.interval {
                    os_signpost(.event, log: Self.log, name: "EmployeeCachedTranscriptReady", signpostID: interval)
                }
            }
        }
    }

    func noteLiveReady() {
        if let interval {
            os_signpost(.event, log: Self.log, name: "EmployeeLiveChatReady", signpostID: interval)
        }
    }

    func finish(_ outcome: WidgetLaunchOutcome?, recoversAfterTransportLoss: Bool = false) {
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
