#if LAA_BUILD
import SwiftUI

/// The Bridge only exposes this device and the current personal viewer. Local
/// submissions remain protected until the matching result is actually read.
struct LAAPersonalPendingView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let viewerId: String
    @State private var operations: [LAAPersonalOperationResponse.Operation] = []
    @State private var selected: LAAPersonalOperationResponse.Operation?
    @State private var showConfirmation = false
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?
    private var localItems: [ComposerDraftStore.Submission] {
        guard let deviceID = bridge.deviceID else { return [] }
        let prefix = "\(deviceID):linear:\(viewerId):"
        return drafts.submissions.filter { $0.key.profile == "laa-bridge" && $0.key.sessionID.hasPrefix(prefix) }
    }
    private func inboxTarget(_ item: ComposerDraftStore.Submission) -> String? {
        guard let device = bridge.deviceID else { return nil }
        let prefix = "\(device):linear:\(viewerId):inbox:"
        guard item.key.sessionID.hasPrefix(prefix) else { return nil }
        let id = String(item.key.sessionID.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    var body: some View {
        List {
            if let error { Text(verbatim: error).foregroundStyle(LAAColor.attention) }
            Section("On This Device") {
                Text(verbatim: "送信前の記録と未確認の要求です。結果を確認するまで内容を保持します。")
                    .laaTextStyle(.secondary)
                if localItems.isEmpty { Text(verbatim: "保留中の要求はありません。") }
                ForEach(localItems) { item in
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        if let device = bridge.deviceID, LAAPersonalTaskQueue.isDependency(item, device: device, viewer: viewerId) {
                            if let value = LAAPersonalTaskQueue.dependency(item, device: device, viewer: viewerId) {
                                Text(verbatim: "作成待ちへの \(value.kind.title)").fontWeight(.semibold)
                                Text(verbatim: value.first).textSelection(.enabled)
                                if !value.second.isEmpty { Text(verbatim: value.second).textSelection(.enabled) }
                                Text(verbatim: "元の作成が未確認・未適用の場合は送信しません。拒否・未適用の場合は内容を確認してください。")
                                    .laaTextStyle(.secondary)
                                Button("Process Queue") { Task { await processQueue() } }.disabled(busy)
                            } else {
                                Text(verbatim: "送信待ちの内容を読み取れません。記録は保持しています。")
                                    .foregroundStyle(LAAColor.attention)
                            }
                        } else {
                            if let id = inboxTarget(item) {
                                Text(verbatim: "Inbox: \(item.draft.text) · \(id)").textSelection(.enabled).laaTextStyle(.secondary)
                                NavigationLink("Open Notification", destination: LAAPersonalInboxItemView(drafts: drafts, viewerId: viewerId, id: id))
                            } else {
                                Text(verbatim: item.key.sessionID).textSelection(.enabled).laaTextStyle(.secondary)
                            }
                            Button(LAACopy.WorkTab.checkStatus) { Task { await check(item) } }.disabled(busy)
                            Button("Return to Draft if Unsent") { Task { await check(item, abandonIfUnsent: true) } }.disabled(busy)
                        }
                        if !LAAWorkDrafts.canRepeat(item) {
                            Text(verbatim: "期限を過ぎているため再送できません。保存先を確認して照合してください。")
                                .laaTextStyle(.secondary)
                        }
                    }
                }
            }
            Section("Unresolved on Mac") {
                Text(verbatim: "対象をLinearで確認した後、適用済みか未適用かを選べます。判断できない場合は保留してください。")
                    .laaTextStyle(.secondary)
                if loaded && operations.isEmpty { Text(verbatim: "未解決の記録はありません。") }
                ForEach(operations) { operation in
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        Text(verbatim: "\(operation.kind) · \(operation.status)").fontWeight(.semibold)
                        Text(verbatim: "対象: \(operation.targetId)").textSelection(.enabled)
                        if let context = operation.contextId {
                            Text(verbatim: "タスク: \(context)").textSelection(.enabled)
                            NavigationLink("Open Task", destination: LAAWorkTaskDetailView(id: context, drafts: drafts))
                        } else if operation.kind.hasPrefix("inbox_") {
                            NavigationLink("Open Notification", destination: LAAPersonalInboxItemView(drafts: drafts, viewerId: viewerId, id: operation.targetId))
                        } else if ["update", "create"].contains(operation.kind) {
                            NavigationLink("Open Task", destination: LAAWorkTaskDetailView(id: operation.targetId, drafts: drafts))
                        }
                        if let created = operation.createdAt { Text(verbatim: "開始: \(LAAWorkPresentation.date(created))").laaTextStyle(.secondary) }
                        if operation.kind == "attachment" {
                            Text(verbatim: "リンクが既存項目へ統合されることがあります。タスク内のリンクも確認してください。")
                                .laaTextStyle(.secondary)
                        }
                        if operation.status == "outcome_unknown" {
                            Button("Reconcile") { selected = operation; showConfirmation = true }.disabled(busy)
                        }
                    }.padding(.vertical, LAASpacing.x1)
                }
            }
            Button("Refresh") { Task { await processQueue() } }.disabled(busy)
        }
        .navigationTitle("Pending")
        .task(id: bridge.revision) { await processQueue() }
        .confirmationDialog("確認した結果を選んでください", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Confirmed Applied") { if let selected { Task { await resolve(selected, as: "applied") } } }
            Button("Confirmed Not Applied") { if let selected { Task { await resolve(selected, as: "not_applied") } } }
            Button(LAACopy.WorkTab.close, role: .cancel) { }
        } message: {
            Text(verbatim: "Linearの対象を確認した結果を記録します。未適用と確認できた場合だけ下書きに戻してください。")
        }
    }

    @MainActor private func processQueue() async {
        busy = true
        await LAAPersonalTaskQueue.run(drafts: drafts, bridge: bridge, viewer: viewerId)
        busy = false
        await load()
    }
    @MainActor private func load() async {
        busy = true; defer { busy = false }
        do {
            let result: LAAPersonalOperationList = try await bridge.read("/v1/task-operations")
            guard result.viewerId == viewerId else { throw LAABridgeError.conflict }
            operations = result.items; loaded = true; error = nil
        } catch let failure as LAABridgeError { error = failure.japaneseText }
        catch { self.error = "保留記録を読み取れませんでした。" }
    }
    @MainActor private func check(_ item: ComposerDraftStore.Submission, abandonIfUnsent: Bool = false) async {
        guard let (_, requestKey) = LAAWorkDrafts.request(item) else { error = "要求記録を読み取れません。"; return }
        busy = true; defer { busy = false }
        do {
            let body = abandonIfUnsent ? try JSONSerialization.data(withJSONObject: ["expectedViewerId": viewerId], options: [.sortedKeys]) : nil
            let result: LAABridgeResponse<LAAPersonalOperationResponse> = try await bridge.request(
                method: abandonIfUnsent ? "POST" : "GET",
                path: abandonIfUnsent ? "/v1/task-operations/abandon-unsent" : "/v1/task-operations/by-key",
                jsonBody: body, idempotencyKey: requestKey)
            let operation = result.data.operation
            switch LAAPersonalReconciliation.disposition(operation, mayCompare: operation.kind == "update") {
            case .complete:
                if !drafts.finishSubmission(item.id, restoring: false) { error = "結果を端末に保存できませんでした。" }
                else { error = nil }
            case .compare:
                error = "本文の競合をタスク編集画面で確認してください。"
            case .restore:
                if !drafts.finishSubmission(item.id, restoring: true) { error = "下書きに戻せませんでした。" }
                else { error = "未適用を確認できたため、下書きに戻しました。" }
            case .invalid: throw LAABridgeError.invalidResponse
            case .wait: error = "結果は未確認です。Mac側の記録から対象を確認してください。"
            }
        } catch let failure as LAABridgeHTTPError {
            if failure.code == "operation_not_found" {
                error = inboxTarget(item) != nil
                    ? "Macに記録がありません。Return to Draft if Unsent で未送信を確定してください。"
                    : "Macに記録がありません。元の編集画面で同じ要求を再試行できます。"
            } else { error = LAAWorkHTTP.message(failure) }
        } catch { self.error = "要求の結果を読み取れませんでした。" }
    }
    @MainActor private func resolve(_ operation: LAAPersonalOperationResponse.Operation, as resolution: String) async {
        guard let key = LAABridgeIdempotencyKey(restoring: "resolve-\(operation.operationId)-\(resolution)"),
              let body = try? JSONSerialization.data(withJSONObject: ["confirmed": true, "resolution": resolution], options: [.sortedKeys]) else {
            error = "照合要求を作れませんでした。"; return
        }
        busy = true
        do {
            let result: LAABridgeResponse<LAAPersonalOperationResponse> = try await bridge.request(
                method: "POST", path: "/v1/task-operations/\(operation.operationId)/resolve", jsonBody: body, idempotencyKey: key)
            guard result.data.operation.status == "resolved", result.data.operation.resolution == resolution else { throw LAABridgeError.invalidResponse }
            operations.removeAll { $0.operationId == operation.operationId }
            error = "照合を記録しました。端末側の要求も状態を確認してください。"
        } catch { self.error = "照合結果を確認できませんでした。同じ結果で再確認してください。" }
        busy = false
    }
}
#endif
