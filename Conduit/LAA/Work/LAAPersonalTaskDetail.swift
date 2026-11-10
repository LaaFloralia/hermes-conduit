#if LAA_BUILD
import SwiftUI

struct LAAPersonalTaskDetailView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.laaDesktop) private var laaDesktop
    @ObservedObject var drafts: ComposerDraftStore
    let id: String
    /// The list row's short number; this route does not carry one itself.
    let ref: String?
    /// The owner-scope row that opened this detail: only it carries the run
    /// record and may be completed. Browsed issues show no run controls.
    let ownerTask: LAALinearTask?
    let onCompleted: ((String) -> Void)?
    @State private var task: LAAPersonalTask?
    @State private var viewerId: String?
    @State private var error: String?
    @State private var showEdit = false
    @State private var confirmingComplete = false
    @State private var completing = false
    @State private var completionFailure: String?
    @State private var completionUnknown = false

    init(id: String, drafts: ComposerDraftStore, ref: String? = nil, ownerTask: LAALinearTask? = nil,
         onCompleted: ((String) -> Void)? = nil) {
        self.id = id; self.drafts = drafts; self.ref = ref
        self.ownerTask = ownerTask; self.onCompleted = onCompleted
    }

    var body: some View {
        ZStack {
            LAAColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
                        if task != nil { Text(verbatim: "前回取得した内容です。") }
                        Button(LAACopy.WorkTab.retry) { Task { await load() } }
                    }
                    if let task {
                        Text(verbatim: task.title).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                            .accessibilityIdentifier("work.task.detail.title")
                        // The short number the owner says, then Linear's own
                        // identifier.
                        Text(verbatim: [LAAWorkRef.display(ref), identifier(task.sourceId)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .laaTextStyle(.secondary).monospacedDigit()
                            .foregroundStyle(LAAColor.secondaryText)
                            .accessibilityIdentifier("work.task.detail.ref")
                        VStack(alignment: .leading, spacing: LAASpacing.x2) {
                            Text(verbatim: "状態: \(task.status?.name ?? "未確認")")
                            Text(verbatim: "担当: \(task.owner?.name ?? "未設定")")
                            if let delegate = task.executor?.name { Text(verbatim: "委任先: \(delegate)") }
                            Text(verbatim: "チーム: \(task.team?.name ?? "未確認")")
                            Text(verbatim: "Project: \(task.project?.name ?? "未設定")")
                            Text(verbatim: "Milestone: \(task.milestone?.name ?? "未設定")")
                            Text(verbatim: "Cycle: \(task.cycle?.name ?? task.cycle?.number.map(String.init) ?? "未設定")")
                            Text(verbatim: "優先度: \(task.priority.map(String.init) ?? "未確認")")
                            Text(verbatim: "見積り: \(task.estimate.map { String($0) } ?? "未設定")")
                            Text(verbatim: "期限: \(task.dueDate ?? "未設定")")
                            if let parent = task.parent { Text(verbatim: "親: \(parent.identifier ?? parent.title ?? parent.id)") }
                            Text(verbatim: "ラベル: \((task.labels ?? []).map(\.name).joined(separator: ", "))")
                            if task.labelsComplete != true { Text(verbatim: "ラベルは一部のみ表示しています。") }
                            Text(verbatim: "更新: \(LAAWorkPresentation.date(task.updatedAt))")
                        }.workCard()
                        if let ownerTask { runCard(ownerTask) }
                        if let description = task.description, !description.isEmpty {
                            MarkdownText(source: description, foregroundStyle: LAAColor.text).workCard()
                            if description.lowercased().contains("https://uploads.linear.app/"), let viewerId {
                                LAAPersonalMarkdownFiles(taskPath: "/v1/personal-tasks/" + (task.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""),
                                                         viewerId: viewerId, commentId: nil).workCard()
                            }
                        }
                        LAATaskSessionsSection(task: task)
                        if let viewerId {
                            LAAPersonalTaskConnections(drafts: drafts, task: task, viewerId: viewerId)
                        }
                        if let raw = task.url, let url = URL(string: raw), url.scheme?.lowercased() == "https" {
                            Link(LAACopy.WorkTab.openLinear, destination: url).buttonStyle(.bordered)
                        }
                    } else if error == nil { LAAWorkSkeleton() }
                }.padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4)
                    .frame(maxWidth: laaDesktop ? LAADesktopMetrics.documentWidth : 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: laaDesktop ? .center : .leading)
            }
        }
        .navigationTitle(Text(verbatim: LAACopy.WorkTab.task))
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(LAACopy.WorkTab.edit) { showEdit = true }.disabled(task == nil || viewerId == nil || error != nil)
            }
        }
        .sheet(isPresented: $showEdit, onDismiss: { Task { await load() } }) {
            if let task, let viewerId { LAAPersonalTaskEditor(task: task, viewerId: viewerId, drafts: drafts).environmentObject(bridge) }
        }
        .confirmationDialog(Text(verbatim: "完了にしますか？"),
                            isPresented: Binding(get: { confirmingComplete }, set: { confirmingComplete = $0 }),
                            titleVisibility: .visible) {
            Button { if let ownerTask { Task { await complete(ownerTask) } } } label: { Text(verbatim: "完了") }
            Button(role: .cancel) {} label: { Text(verbatim: LAACopy.cancel) }
        } message: {
            Text(verbatim: ownerTask.map(LAATaskRunCopy.completionMessage(for:)) ?? "")
        }
        .task(id: "\(id):\(bridge.revision)") { task = nil; viewerId = nil; await load() }
    }

    /// The Bridge's execution record: 担当, the model it started with, the
    /// status the list shows, the session and the report. The 完了 button is
    /// disabled while the session is running, with the reason beside it.
    @ViewBuilder private func runCard(_ owner: LAALinearTask) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: "実行").fontWeight(.semibold)
            runRow("担当", owner.assigneeDisplay)
            if let model = owner.run?.profileLabel ?? owner.run?.profile { runRow("モデル", model) }
            if let status = owner.runStatus {
                HStack(spacing: LAASpacing.x2) {
                    Text(verbatim: "実施").foregroundStyle(LAAColor.secondaryText)
                    Spacer(minLength: 0)
                    Text(verbatim: status.label).fontWeight(.semibold).foregroundStyle(status.color)
                }
                .accessibilityIdentifier("work.task.detail.status")
                if let session = status.sessionID {
                    Button {
                        guard let url = URL(string: "laa://work/sessions/\(session)") else { return }
                        LAAWorkLinkRequest.shared.open(url)
                    } label: { Text(verbatim: "セッションを開く").laaTextStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            if let report = owner.run?.report, !report.summary.isEmpty {
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: "報告").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    Text(verbatim: report.summary).foregroundStyle(LAAColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let reason = owner.completionBlockedReason {
                Text(verbatim: reason).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    .accessibilityIdentifier("work.task.detail.completeReason")
            }
            if owner.isOpen {
                Button { confirmingComplete = true } label: {
                    Label { Text(verbatim: "完了") } icon: { Image(systemName: "checkmark") }
                        .frame(minHeight: LAASpacing.minimumTouchTarget)
                }
                .buttonStyle(.bordered)
                .disabled(completing || owner.completionBlockedReason != nil)
                .accessibilityIdentifier("work.task.detail.complete")
            }
            if completing { Text("保存中").font(.caption) }
            if let completionFailure {
                Text(verbatim: completionFailure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("work.task.detail.completeFailure")
                if completionUnknown, owner.isOpen {
                    Button { Task { await complete(owner) } } label: { Text(verbatim: "もう一度確認") }
                        .laaTextStyle(.secondary)
                }
            }
        }.workCard()
    }

    private func runRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: LAASpacing.x2) {
            Text(verbatim: label).foregroundStyle(LAAColor.secondaryText)
            Spacer(minLength: 0)
            Text(verbatim: value)
        }
    }

    @MainActor private func complete(_ owner: LAALinearTask) async {
        guard !completing, let device = bridge.deviceID else { return }
        completing = true; completionFailure = nil; completionUnknown = false
        defer { completing = false }
        let key = LAAWorkDrafts.key(deviceID: device, target: "linear-owner-operation")
        switch await LAALinearTaskCompletion.complete(owner, bridge: bridge, drafts: drafts, key: key) {
        case .completed:
            onCompleted?(owner.id)
            dismiss()
        case .failed(let message):
            completionFailure = message
        case .unknown:
            completionFailure = "完了の結果を確認できません。接続を確認して、もう一度お試しください。"
            completionUnknown = true
        }
    }

    /// `linear:BUS-123` → `BUS-123`; the identifier itself is kept as is.
    private func identifier(_ sourceId: String) -> String {
        sourceId.hasPrefix("linear:") ? String(sourceId.dropFirst("linear:".count)) : sourceId
    }

    @MainActor private func load() async {
        do {
            let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            let detail: LAAPersonalTaskResponse = try await bridge.read("/v1/personal-tasks/\(safe)")
            task = detail.task; viewerId = detail.viewerId; error = nil
        } catch is CancellationError {
        } catch let failure as LAABridgeError { error = failure.japaneseText }
        catch { self.error = "タスクを読み取れませんでした。" }
    }
}
#endif
