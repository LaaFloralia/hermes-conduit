#if LAA_BUILD
import SwiftUI

private enum LAAPersonalInboxPath {
    static func item(_ id: String) -> String? {
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,200}$"#, options: .regularExpression) != nil,
              let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return "/v1/task-inbox/" + encoded
    }
}

struct LAAPersonalInboxView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let viewerId: String
    let onExit: () -> Void
    @State private var snapshot: LAAPersonalInboxSnapshot?
    @State private var includeArchived = false
    @State private var loading = false
    @State private var working = false
    @State private var operationCheckOK = false
    @State private var unresolved = Set<String>()
    @State private var generation = UUID()
    @State private var error: String?
    @State private var operationError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x3) {
                Toggle("Include Archived", isOn: $includeArchived)
                Text(verbatim: "取得や表示だけでは既読にしません。最新の状態は更新して確認してください。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(LAAColor.attention)
                    if snapshot != nil { Text(verbatim: "取得済みの内容は更新されていない場合があります。") }
                }
                if let operationError { Text(verbatim: operationError).foregroundStyle(LAAColor.attention) }
                if let snapshot {
                    Text(verbatim: "\(snapshot.summary) · 更新: \(LAAWorkPresentation.date(snapshot.observedAt))")
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    if snapshot.nextCursor != nil {
                        Text(verbatim: "ページ間で通知が変わる場合があります。")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                    if snapshot.items.isEmpty && snapshot.nextCursor == nil && !loading && error == nil {
                        Text(verbatim: "通知はありません。").foregroundStyle(LAAColor.secondaryText)
                    }
                    ForEach(snapshot.items) { item in
                        notificationRow(item)
                    }
                    if snapshot.nextCursor != nil {
                        Button(LAACopy.WorkTab.loadMore) { Task { await load(reset: false) } }.disabled(loading || working)
                    }
                }
                if loading { ProgressView().accessibilityLabel(Text(verbatim: "読み込み中")) }
                HStack {
                    Button("Refresh") { Task { await refresh() } }.disabled(loading || working)
                    NavigationLink("Pending", destination: LAAPersonalPendingView(drafts: drafts, viewerId: viewerId))
                }
            }
            .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .refreshable { await refresh() }
        .task(id: "\(bridge.revision)-\(viewerId)-\(includeArchived)") { await refresh() }
        .onDisappear(perform: onExit)
    }

    @ViewBuilder private func notificationRow(_ item: LAAPersonalNotification) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            LAAPersonalNotificationContent(item: item, drafts: drafts)
            let locallyPending = draftKey(item.id).flatMap { LAAWorkDrafts.pending(drafts, key: $0) } != nil
            if locallyPending || unresolved.contains(item.id) {
                Text(verbatim: "この通知の操作は確認待ちです。Pendingで結果を確認してください。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            }
            HStack {
                Button(item.isUnread ? "Mark Read" : "Mark Unread") {
                    Task { await change(item, action: item.isUnread ? "read" : "unread") }
                }
                .accessibilityIdentifier("work.inbox.read.\(item.id)")
                Button(item.isArchived ? "Restore" : "Archive") {
                    Task { await change(item, action: item.isArchived ? "unarchive" : "archive") }
                }
                .accessibilityIdentifier("work.inbox.archive.\(item.id)")
            }
            .buttonStyle(.bordered)
            .disabled(loading || working || !operationCheckOK || error != nil || locallyPending || unresolved.contains(item.id))
        }
        .workCard()
        .accessibilityIdentifier("work.inbox.item.\(item.id)")
    }

    private func draftKey(_ id: String) -> ComposerDraftKey? {
        bridge.deviceID.map { LAAWorkDrafts.key(deviceID: $0, target: "linear:\(viewerId):inbox:\(id)") }
    }
    @MainActor private func refresh() async {
        await load(reset: true)
        guard !Task.isCancelled else { return }
        await loadOperations()
    }
    @MainActor private func load(reset: Bool) async {
        if !reset && (loading || snapshot?.nextCursor == nil) { return }
        let currentGeneration = reset ? UUID() : generation
        if reset { generation = currentGeneration; snapshot = nil; operationCheckOK = false }
        loading = true; error = nil
        defer { if generation == currentGeneration { loading = false } }
        var query = [URLQueryItem(name: "includeArchived", value: includeArchived ? "true" : "false")]
        if !reset, let cursor = snapshot?.nextCursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        do {
            let page: LAAPersonalPage<LAAPersonalNotification> = try await bridge.read(LAAWorkPresentation.path("/v1/task-inbox", query: query))
            guard !Task.isCancelled, generation == currentGeneration else { return }
            var result = reset ? LAAPersonalInboxSnapshot(viewerId: viewerId) : (snapshot ?? LAAPersonalInboxSnapshot(viewerId: viewerId))
            try result.merge(page, reset: reset)
            snapshot = result
        } catch is CancellationError {
        } catch LAAPersonalInboxSnapshot.Failure.viewerChanged {
            if generation == currentGeneration { snapshot = nil; operationCheckOK = false; error = "Linearの本人が変わりました。Tasksを更新してください。" }
        } catch let failure as LAABridgeError {
            if generation == currentGeneration && !Task.isCancelled { error = failure.japaneseText }
        } catch {
            if generation == currentGeneration && !Task.isCancelled { self.error = "通知を読み取れませんでした。" }
        }
    }
    @MainActor private func loadOperations() async {
        operationCheckOK = false
        do {
            let result: LAAPersonalOperationList = try await bridge.read("/v1/task-operations")
            guard !Task.isCancelled, result.viewerId == viewerId else { throw LAABridgeError.conflict }
            unresolved = Set(result.items.filter { $0.kind.hasPrefix("inbox_") }.map(\.targetId))
            operationError = nil; operationCheckOK = true
        } catch {
            if !Task.isCancelled { operationError = "操作の確認状態を読み取れません。更新後に操作してください。" }
        }
    }
    @MainActor private func change(_ item: LAAPersonalNotification, action: String) async {
        guard !working, !loading, operationCheckOK, error == nil, !unresolved.contains(item.id),
              let path = LAAPersonalInboxPath.item(item.id), let localKey = draftKey(item.id),
              LAAWorkDrafts.pending(drafts, key: localKey) == nil else { return }
        let key = LAABridgeIdempotencyKey()
        guard let body = try? JSONSerialization.data(withJSONObject: ["expectedViewerId": viewerId, "action": action], options: [.sortedKeys]),
              let submission = LAAWorkDrafts.reserve(drafts, key: localKey, text: action, body: body, idempotency: key) else {
            operationError = "要求を端末に保存できませんでした。"; return
        }
        working = true
        do {
            let result: LAABridgeResponse<LAAPersonalOperationResponse> = try await bridge.request(
                method: "PATCH", path: path, jsonBody: body, idempotencyKey: key)
            guard result.data.operation.status == "succeeded", result.data.operation.kind == "inbox_\(action)",
                  result.data.operation.targetId == item.id, result.data.operation.resultId == item.id else { throw LAABridgeError.invalidResponse }
            guard drafts.finishSubmission(submission.id, restoring: false) else { throw LAABridgeError.invalidResponse }
            working = false
            await refresh()
        } catch {
            drafts.markSubmissionUnknown(submission.id)
            working = false
            operationError = "結果を確認できません。Pendingで状態を確認してください。自動で再送しません。"
            await loadOperations()
            if operationError == nil { operationError = "結果を確認できません。Pendingで状態を確認してください。自動で再送しません。" }
        }
    }
}

private struct LAAPersonalNotificationContent: View {
    let item: LAAPersonalNotification
    @ObservedObject var drafts: ComposerDraftStore
    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            HStack {
                Text(verbatim: item.isUnread ? "未読" : "既読")
                    .fontWeight(.semibold).foregroundStyle(item.isUnread ? LAAColor.attention : LAAColor.secondaryText)
                if item.isArchived { Text(verbatim: "保管済み").foregroundStyle(LAAColor.secondaryText) }
            }
            Text(verbatim: item.title?.isEmpty == false ? item.title! : item.type).fontWeight(.semibold)
            if let subtitle = item.subtitle, !subtitle.isEmpty { Text(verbatim: subtitle) }
            if let actor = item.actor?.name, !actor.isEmpty { Text(verbatim: actor).laaTextStyle(.secondary) }
            if let issue = item.issue {
                NavigationLink(destination: LAAWorkTaskDetailView(id: issue.id, drafts: drafts)) {
                    Text(verbatim: "\(issue.identifier) · \(issue.title)")
                }
            }
            Text(verbatim: "通知ID: \(item.id)").textSelection(.enabled).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            Text(verbatim: "更新: \(LAAWorkPresentation.date(item.updatedAt))").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }
    }
}

/// A single recipient-checked notification remains readable even if archived.
/// It gives the owner the current state to inspect before resolving an unknown write.
struct LAAPersonalInboxItemView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let viewerId: String
    let id: String
    @State private var item: LAAPersonalNotification?
    @State private var error: String?
    @State private var observedAt: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x3) {
                Text(verbatim: "現在の状態を確認してください。他の端末からの変更があると、この状態だけでは操作の成否を断定できません。")
                    .laaTextStyle(.secondary)
                if let error { Text(verbatim: error).foregroundStyle(LAAColor.attention) }
                if let item {
                    LAAPersonalNotificationContent(item: item, drafts: drafts).workCard()
                    Text(verbatim: "取得: \(LAAWorkPresentation.date(observedAt))").laaTextStyle(.secondary)
                } else if error == nil { ProgressView() }
                Button("Refresh") { Task { await load() } }
            }.padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4)
        }
        .navigationTitle("Notification")
        .task(id: "\(bridge.revision)-\(viewerId)-\(id)") { await load() }
    }
    @MainActor private func load() async {
        item = nil; observedAt = nil; error = nil
        do {
            guard let path = LAAPersonalInboxPath.item(id) else { throw LAABridgeError.invalidResponse }
            let response: LAAPersonalNotificationResponse = try await bridge.read(path)
            guard !Task.isCancelled, response.viewerId == viewerId, response.notification.id == id else { throw LAABridgeError.conflict }
            item = response.notification; observedAt = response.observedAt
        } catch is CancellationError {
        } catch { if !Task.isCancelled { self.error = "通知を読み取れませんでした。" } }
    }
}
#endif
