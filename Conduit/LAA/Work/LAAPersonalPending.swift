#if LAA_BUILD
import SwiftUI

/// Pending must remain accessible even if Keychain or the Mac is unavailable.
/// Until the viewer can be verified, only anonymous local entries may be
/// discarded; their content and all network actions remain unavailable.
struct LAAPersonalPendingOfflineView: View {
    @ObservedObject var drafts: ComposerDraftStore
    @State private var selected: ComposerDraftStore.Submission?
    @State private var showDiscard = false
    @State private var error: String?
    private var items: [ComposerDraftStore.Submission] { LAAWorkDrafts.personalSubmissions(drafts) }

    var body: some View {
        List {
            if let error { Text(verbatim: error).foregroundStyle(LAAColor.attention) }
            if drafts.persistenceFailed {
                Text(verbatim: "端末の保留を読み取れないか保存できません。ロックを解除して再起動してください。")
                    .foregroundStyle(LAAColor.attention)
            }
            Section("この端末の保留") {
                Text(verbatim: "本人と接続先を確認できないため、内容は表示しません。\(items.count)件。")
                    .accessibilityIdentifier("work.pending.offline.count")
                if items.isEmpty && !drafts.persistenceFailed { Text(verbatim: "保留中の要求はありません。") }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        Text(verbatim: "保留 \(index + 1)")
                        Spacer()
                        Button("破棄", role: .destructive) { selected = item; showDiscard = true }
                            .accessibilityIdentifier("work.pending.offline.discard")
                    }
                }
            }
        }
        .navigationTitle("Pending")
        .confirmationDialog("この保留を端末から破棄しますか？", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("端末から破棄", role: .destructive) {
                if let item = selected {
                    error = drafts.finishSubmission(item.id, restoring: false) ? nil : "記録を破棄できませんでした。"
                }
            }
            Button(LAACopy.WorkTab.close, role: .cancel) { }
        } message: { Text(verbatim: "Linearで状態を確認してください。破棄しても元の要求が適用済み、または処理中の可能性があります。Mac側の記録は変更しません。") }
    }
}

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
    @State private var orphanToDiscard: ComposerDraftStore.Submission?
    @State private var showDiscard = false
    @State private var originalResults: [UUID: LAAPersonalOperationResponse.Operation] = [:]
    @State private var compactedResults: [UUID: LAAWorkHTTP.CompactedResult] = [:]
    @State private var verifiedTaskIDs: [String: String] = [:]
    @State private var originalToResolve: ComposerDraftStore.Submission?
    @State private var showOriginalConfirmation = false
    private var localItems: [ComposerDraftStore.Submission] {
        guard let deviceID = bridge.deviceID else { return [] }
        let prefix = "\(deviceID):linear:\(viewerId):"
        return drafts.submissions.filter { $0.key.profile == "laa-bridge" && $0.key.sessionID.hasPrefix(prefix) }
    }
    private var orphanItems: [ComposerDraftStore.Submission] {
        guard let device = bridge.deviceID else { return [] }
        let prefix = "\(device):linear:\(viewerId):"
        return drafts.submissions.filter { $0.key.dashboardID == LAAWorkDrafts.dashboardID &&
            $0.key.profile == "laa-bridge" && $0.key.sessionID.contains(":linear:") && !$0.key.sessionID.hasPrefix(prefix) }
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
                        if item.personalOrigin != nil {
                            Text(verbatim: "移した下書き。元の要求の結果を確認するまで自動送信しません。")
                            if let (body, _) = LAAWorkDrafts.originalRequest(item),
                               let value = try? JSONDecoder().decode(LAAPersonalDependency.self, from: body) {
                                Text(verbatim: "作成待ちへの \(value.kind.title)").fontWeight(.semibold)
                                Text(verbatim: value.first).textSelection(.enabled)
                                if !value.second.isEmpty { Text(verbatim: value.second).textSelection(.enabled) }
                            }
                            if let operation = originalResults[item.id] {
                                Text(verbatim: "\(operation.status) · 対象: \(operation.targetId)").textSelection(.enabled)
                                if ["create", "update"].contains(operation.kind) {
                                    taskLink(operation)
                                }
                                if operation.status == "outcome_unknown" {
                                    Button("Reconcile") { originalToResolve = item; showOriginalConfirmation = true }.disabled(busy)
                                }
                            }
                            Button("元の要求の状態を確認") { Task { await checkOriginal(item) } }.disabled(busy)
                            if compactedResults[item.id] == nil || compactedResults[item.id] == .rejected {
                                Button("未送信・未適用なら下書きに戻す") { Task { await checkOriginal(item, abandonIfUnsent: true) } }.disabled(busy)
                            }
                        } else if let device = bridge.deviceID, LAAPersonalTaskQueue.isDependency(item, device: device, viewer: viewerId) {
                            if let value = LAAPersonalTaskQueue.dependency(item, device: device, viewer: viewerId) {
                                Text(verbatim: "作成待ちへの \(value.kind.title)").fontWeight(.semibold)
                                Text(verbatim: value.first).textSelection(.enabled)
                                if !value.second.isEmpty { Text(verbatim: value.second).textSelection(.enabled) }
                                Text(verbatim: "元の作成が未確認・未適用の場合は送信しません。拒否・未適用の場合は内容を確認してください。")
                                    .laaTextStyle(.secondary)
                                Text(verbatim: "元の課題を確認できないときは、内容をコピーしてから破棄できます。")
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
                            if compactedResults[item.id] == nil || compactedResults[item.id] == .rejected {
                                Button("Return to Draft if Unsent") { Task { await check(item, abandonIfUnsent: true) } }.disabled(busy)
                            }
                        }
                        if item.personalOrigin == nil && !LAAWorkDrafts.canRepeat(item) {
                            Text(verbatim: "期限を過ぎているため再送できません。保存先を確認して照合してください。")
                                .laaTextStyle(.secondary)
                        }
                        Button("破棄", role: .destructive) { orphanToDiscard = item; showDiscard = true }
                            .disabled(busy).accessibilityIdentifier("work.pending.discard.local")
                    }
                }
            }
            Section("別の端末・別の本人") {
                Text(verbatim: "\(orphanItems.count)件。内容は表示せず、選んだ記録だけを操作します。")
                    .laaTextStyle(.secondary).accessibilityIdentifier("work.pending.orphan.count")
                ForEach(Array(orphanItems.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        Text(verbatim: "保留 \(index + 1)")
                        Button("この端末の下書きへ移す") { moveOrphan(item) }.disabled(busy)
                            .accessibilityIdentifier("work.pending.orphan.move")
                        Button("破棄", role: .destructive) { orphanToDiscard = item; showDiscard = true }.disabled(busy)
                            .accessibilityIdentifier("work.pending.orphan.discard")
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
                            taskLink(operation)
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
        .task(id: bridge.revision) { verifiedTaskIDs.removeAll(); await processQueue() }
        .confirmationDialog("この保留を端末から破棄しますか？", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("端末から破棄", role: .destructive) {
                if let item = orphanToDiscard {
                    error = drafts.finishSubmission(item.id, restoring: false) ? nil : "記録を破棄できませんでした。"
                }
            }
            Button(LAACopy.WorkTab.close, role: .cancel) { }
        } message: { Text(verbatim: "Linearで状態を確認してください。破棄しても元の要求が適用済み、または処理中の可能性があります。Mac側の記録は変更しません。") }
        .confirmationDialog("元の要求の確認結果を選んでください", isPresented: $showOriginalConfirmation, titleVisibility: .visible) {
            Button("Confirmed Applied") { if let item = originalToResolve { Task { await resolveOriginal(item, as: "applied") } } }
            Button("Confirmed Not Applied") { if let item = originalToResolve { Task { await resolveOriginal(item, as: "not_applied") } } }
            Button(LAACopy.WorkTab.close, role: .cancel) { }
        } message: { Text(verbatim: "Linearの対象を確認した結果を記録します。判断できない場合は保留してください。") }
        .confirmationDialog("確認した結果を選んでください", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Confirmed Applied") { if let selected { Task { await resolve(selected, as: "applied") } } }
            Button("Confirmed Not Applied") { if let selected { Task { await resolve(selected, as: "not_applied") } } }
            Button(LAACopy.WorkTab.close, role: .cancel) { }
        } message: {
            Text(verbatim: "Linearの対象を確認した結果を記録します。未適用と確認できた場合だけ下書きに戻してください。")
        }
    }

    @ViewBuilder private func taskLink(_ operation: LAAPersonalOperationResponse.Operation) -> some View {
        if let id = verifiedTaskIDs[operation.operationId] {
            NavigationLink("Open Task", destination: LAAWorkTaskDetailView(id: id, drafts: drafts))
        } else if LAAPersonalReconciliation.taskLookup(operation) != nil {
            Button("タスクを読み戻す") { Task { await verifyTask(operation) } }.disabled(busy)
        }
    }
    @MainActor private func verifyTask(_ operation: LAAPersonalOperationResponse.Operation) async {
        guard let device = bridge.deviceID, let lookup = LAAPersonalReconciliation.taskLookup(operation),
              let safe = lookup.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }
        busy = true; defer { busy = false }
        do {
            let response: LAAPersonalTaskResponse = try await bridge.read("/v1/personal-tasks/\(safe)")
            guard bridge.deviceID == device,
                  let id = LAAPersonalReconciliation.verifiedTaskID(response, operation: operation, viewer: viewerId) else {
                error = "本人またはタスクが一致しません。対象は未確認です。"; return
            }
            verifiedTaskIDs[operation.operationId] = id
            error = nil
        } catch { self.error = "タスクを読み戻せませんでした。未作成の場合もあります。" }
    }

    @MainActor private func moveOrphan(_ item: ComposerDraftStore.Submission) {
        guard let device = bridge.deviceID,
              let destination = LAAWorkDrafts.destination(item, device: device, viewer: viewerId) else {
            error = "元の要求を読み取れないため移せません。記録は保持しています。"; return
        }
        guard drafts.movePersonalSubmission(item.id, to: destination) else {
            error = "同じ場所に下書きがあるか、端末に保存できません。記録は保持しています。"; return
        }
        error = "移しました。結果が不明な要求は元の本人で照合するまで自動送信しません。"
    }
    @MainActor private func checkOriginal(_ item: ComposerDraftStore.Submission, abandonIfUnsent: Bool = false) async {
        guard let origin = LAAWorkDrafts.origin(item), origin.viewer == viewerId,
              let (_, key) = LAAWorkDrafts.originalRequest(item) else {
            error = "元の本人に接続してから、この要求を照合してください。"; return
        }
        let deviceAtStart = bridge.deviceID
        busy = true; defer { busy = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["expectedViewerId": origin.viewer, "originalDeviceId": origin.device], options: [.sortedKeys])
            let result: LAABridgeResponse<LAAPersonalOperationResponse> = try await bridge.request(
                method: "POST", path: abandonIfUnsent ? "/v1/task-operations/original-abandon" : "/v1/task-operations/original-status",
                jsonBody: body, idempotencyKey: key)
            guard let device = bridge.deviceID,
                  item.key == LAAWorkDrafts.destination(item, device: device, viewer: viewerId),
                  drafts.submissions.contains(where: { $0.id == item.id && $0.key == item.key && $0.personalOrigin == item.personalOrigin }) else {
                error = "接続先または保留が変わりました。記録を確認してからやり直してください。"; return
            }
            let operation = result.data.operation
            originalResults[item.id] = operation
            switch LAAPersonalReconciliation.disposition(operation, mayCompare: false) {
            case .complete:
                error = drafts.finishSubmission(item.id, restoring: false) ? "元の操作が適用済みと確認できました。" : "結果を端末に保存できませんでした。"
            case .restore:
                let isInbox = origin.target.hasPrefix("inbox:")
                if origin.target.hasPrefix("dependency:") {
                    await restoreMovedDependency(item, origin: origin, child: operation, body: body)
                } else if !isInbox && drafts.hasDraft(for: item.key) {
                    error = "同じ場所に下書きがあります。内容は保留に残しています。"
                } else if drafts.finishSubmission(item.id, restoring: !isInbox) {
                    error = isInbox ? "未送信または未適用を確認しました。" : "未送信または未適用を確認し、下書きに戻しました。"
                } else { error = "下書きに戻せませんでした。" }
            case .unsent:
                if !abandonIfUnsent { await checkOriginal(item, abandonIfUnsent: true) }
                else { error = "未送信の要求を確定できません。再確認してください。" }
            case .wait:
                error = "結果は未確認です。対象をLinearで確認して照合してください。自動送信しません。"
            case .compare, .invalid: throw LAABridgeError.invalidResponse
            }
        } catch let failure as LAABridgeHTTPError {
            if !handleCompacted(failure, item: item, explicitlyRequested: abandonIfUnsent, deviceAtStart: deviceAtStart, original: true) {
                error = failure.code == "operation_not_found" ? "元のMacに記録がありません。未送信なら下書きに戻す操作で確定してください。" : LAAWorkHTTP.message(failure)
            }
        } catch { self.error = "元の要求の結果を読み取れませんでした。" }
    }
    @MainActor private func restoreMovedDependency(_ item: ComposerDraftStore.Submission, origin: LAAWorkDrafts.Origin,
                                                    child: LAAPersonalOperationResponse.Operation, body: Data) async {
        guard let device = bridge.deviceID, let (request, _) = LAAWorkDrafts.originalRequest(item),
              let value = try? JSONDecoder().decode(LAAPersonalDependency.self, from: request),
              let parentKey = LAABridgeIdempotencyKey(restoring: value.parentKey) else {
            error = "元の作成を確認できません。内容は保留に残しています。"; return
        }
        do {
            let parent: LAABridgeResponse<LAAPersonalOperationResponse> = try await bridge.request(
                method: "POST", path: "/v1/task-operations/original-status", jsonBody: body, idempotencyKey: parentKey)
            guard let target = value.parentTarget(parent.data.operation, device: origin.device, viewer: viewerId) else {
                error = "元のタスクの作成を確認してから戻してください。内容は保留に残しています。"; return
            }
            let verified: LAAPersonalTaskResponse = try await bridge.read("/v1/personal-tasks/\(target)")
            guard bridge.deviceID == device, LAAPersonalTaskQueue.restoreMovedDependency(
                item, drafts: drafts, device: device, viewer: viewerId, child: child,
                parent: parent.data.operation, verified: verified) else {
                error = "対象を確認できないか、同じ場所に下書きがあります。内容は保留に残しています。"; return
            }
            error = "未適用を確認し、元のタスクの下書きに戻しました。タスクを開いて内容を確認してください。"
        } catch { self.error = "元のタスクを確認できません。内容は保留に残しています。" }
    }
    @MainActor private func resolveOriginal(_ item: ComposerDraftStore.Submission, as resolution: String) async {
        guard let origin = LAAWorkDrafts.origin(item), origin.viewer == viewerId,
              let (_, originalKey) = LAAWorkDrafts.originalRequest(item),
              let operation = originalResults[item.id], operation.status == "outcome_unknown",
              let key = LAABridgeIdempotencyKey(restoring: "resolve-\(operation.operationId)-\(resolution)"),
              let body = try? JSONSerialization.data(withJSONObject: ["confirmed": true, "resolution": resolution,
                  "operationId": operation.operationId, "originalKey": originalKey.value, "expectedViewerId": origin.viewer, "originalDeviceId": origin.device], options: [.sortedKeys]) else {
            error = "元の本人と要求の状態を確認してください。"; return
        }
        busy = true
        do {
            let result: LAABridgeResponse<LAAPersonalOperationResponse> = try await bridge.request(
                method: "POST", path: "/v1/task-operations/original-resolve", jsonBody: body, idempotencyKey: key)
            guard result.data.operation.status == "resolved", result.data.operation.resolution == resolution else { throw LAABridgeError.invalidResponse }
            busy = false
            await checkOriginal(item)
        } catch { busy = false; self.error = "照合結果を確認できませんでした。同じ結果で再確認してください。" }
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
        let deviceAtStart = bridge.deviceID
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
                else { error = "未送信または未適用を確認し、下書きに戻しました。" }
            case .unsent:
                // A queue sender can race a read-only status check. Close the
                // key under the ledger lock before restoring any draft.
                if !abandonIfUnsent { await check(item, abandonIfUnsent: true) }
                else { error = "未送信の要求を確定できません。再確認してください。" }
            case .invalid: throw LAABridgeError.invalidResponse
            case .wait: error = "結果は未確認です。Mac側の記録から対象を確認してください。"
            }
        } catch let failure as LAABridgeHTTPError {
            if handleCompacted(failure, item: item, explicitlyRequested: abandonIfUnsent, deviceAtStart: deviceAtStart, original: false) {
                return
            } else if failure.code == "operation_not_found" {
                if !LAAWorkDrafts.canRepeat(item) {
                    error = "Macに記録がなく、再送期限も過ぎています。Linearを確認し、必要ならPendingで破棄してください。"
                } else {
                    error = inboxTarget(item) != nil
                        ? "Macに記録がありません。Return to Draft if Unsent で未送信を確定してください。"
                        : "Macに記録がありません。元の編集画面で同じ要求を再試行できます。"
                }
            } else { error = LAAWorkHTTP.message(failure) }
        } catch { self.error = "要求の結果を読み取れませんでした。" }
    }

    @MainActor private func handleCompacted(_ failure: LAABridgeHTTPError, item: ComposerDraftStore.Submission,
                                             explicitlyRequested: Bool, deviceAtStart: String?, original: Bool) -> Bool {
        guard let result = LAAWorkHTTP.compactedResult(failure) else { return false }
        guard let deviceAtStart, bridge.deviceID == deviceAtStart, bridge.status == .paired,
              drafts.submissions.contains(item) else {
            error = "接続先または保留が変わりました。確認してからやり直してください。"; return true
        }
        compactedResults[item.id] = result
        guard LAAWorkHTTP.mayRestoreCompacted(failure, explicitlyRequested: explicitlyRequested) else {
            error = LAAWorkHTTP.message(failure); return true
        }
        let target = original ? LAAWorkDrafts.origin(item)?.target : nil
        if original && target == nil {
            error = "元の要求を読み取れません。記録は保留に残しています。"; return true
        }
        if target?.hasPrefix("dependency:") == true {
            error = "元のタスクを確認する必要があります。内容をコピーしてから破棄できます。"; return true
        }
        let isInbox = original ? target?.hasPrefix("inbox:") == true : inboxTarget(item) != nil
        switch LAAWorkDrafts.restoreConfirmedRejection(drafts, item: item, isInbox: isInbox) {
        case .restored: error = "未適用を確認し、下書きに戻しました。"
        case .cleared: error = "未適用を確認しました。"
        case .draftExists: error = "同じ場所に下書きがあります。内容は保留に残しています。"
        case .missing: error = "保留が変わりました。確認してからやり直してください。"
        case .saveFailed: error = "下書きに戻せませんでした。"
        }
        return true
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
