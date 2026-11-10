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
    private(set) var workspace: WidgetWorkspaceID?
    private var generation = 0
    private var read: Task<Void, Never>?
    private static let log = OSLog(subsystem: "com.laa.performance", category: .pointsOfInterest)
    private var interval: OSSignpostID?

    static let timeout: Duration = .seconds(8)
    static let unavailable = "Macの会話サービスから応答がありません。接続を確認して再試行してください。"

    func begin(workspace: WidgetWorkspaceID, directory: URL, preferredSessionID: String?) {
        clear()
        self.workspace = workspace
        let interval = OSSignpostID(log: Self.log)
        self.interval = interval
        os_signpost(.begin, log: Self.log, name: "EmployeeConversationOpen", signpostID: interval)
        let generation = generation
        read = Task { [weak self] in
            let presentation = await Task.detached(priority: .userInitiated) {
                Self.load(workspace: workspace, directory: directory, preferredSessionID: preferredSessionID)
            }.value
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.presentation = presentation
        }
    }

    func finish(_ outcome: WidgetLaunchOutcome?) {
        if let interval {
            os_signpost(.end, log: Self.log, name: "EmployeeConversationOpen", signpostID: interval)
            self.interval = nil
        }
        if case .failed(let reason) = outcome {
            // Keep the employee and their copy on screen. Clearing it would
            // expose the previous employee's still-connected conversation.
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
        presentation = nil
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
