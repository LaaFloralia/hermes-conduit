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
                        VStack(alignment: .leading, spacing: LAASpacing.x2) {
                            HStack(spacing: LAASpacing.x2) {
                                // The short number the owner says, then Linear's
                                // own identifier.
                                Text(verbatim: [LAAWorkRef.display(ref), identifier(task.sourceId)]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .laaTextStyle(.secondary).monospacedDigit()
                                    .foregroundStyle(LAAColor.secondaryText)
                                    .accessibilityIdentifier("work.task.detail.ref")
                                if let ownerTask { genreChip(LAATaskGenre.classify(ownerTask)) }
                                Spacer(minLength: LAASpacing.x2)
                                if let ownerTask, ownerTask.isOpen { completeButton(ownerTask) }
                            }
                            Text(verbatim: task.title)
                                .font(LAAType.title(task.title, size: laaDesktop ? 30 : 26, relativeTo: .title))
                                .foregroundStyle(LAAColor.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("work.task.detail.title")
                            if let ownerTask { completionNotes(ownerTask) }
                        }
                        properties(task)
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
                    } else if error == nil { LAALoadingDots() }
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

    /// 完了 beside the number, at the size of the list's glass capsules: a
    /// quiet control, not a slab under the run card (owner, 2026-11-12:
    /// 「ダサい・でかい」). It still asks first. While the session is running
    /// it is disabled, and the run card says why.
    private func completeButton(_ owner: LAALinearTask) -> some View {
        let blocked = owner.completionBlockedReason != nil
        return Button { confirmingComplete = true } label: {
            HStack(spacing: 5) {
                if completing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "checkmark.circle").font(.system(size: 13, weight: .semibold))
                }
                Text(verbatim: completing ? "保存中" : "完了にする").fontWeight(.medium)
            }
            .laaTextStyle(.secondary)
            .foregroundStyle(blocked ? LAAColor.secondaryText : LAAColor.link)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .laaGlass(in: Capsule())
            .opacity(blocked ? 0.6 : 1)
            .frame(minHeight: LAASpacing.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(completing || blocked)
        .accessibilityLabel(Text(verbatim: "完了にする"))
        .accessibilityHint(Text(verbatim: owner.completionBlockedReason ?? ""))
        .accessibilityIdentifier("work.task.detail.complete")
    }

    /// A completion that did not go through, under the title it belongs to.
    @ViewBuilder private func completionNotes(_ owner: LAALinearTask) -> some View {
        if let completionFailure {
            HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                Text(verbatim: completionFailure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("work.task.detail.completeFailure")
                if completionUnknown, owner.isOpen {
                    Button { Task { await complete(owner) } } label: {
                        Text(verbatim: "もう一度確認").laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                    }
                    .buttonStyle(.borderless)
                    .disabled(completing)
                }
            }
        }
    }

    /// The Bridge's execution record: 担当, the model it started with, the
    /// status the list shows, the session and the report. While the session
    /// is running it says why 完了 is disabled.
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
        }.workCard()
    }

    /// Linear's properties as Linear shows them: an icon, a quiet label and the
    /// value, and only the ones that are set. The team is always LAA and is
    /// not repeated.
    private func properties(_ task: LAAPersonalTask) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: LAASpacing.x3, verticalSpacing: LAASpacing.x3) {
            property("circle.dashed", "状態") { Text(verbatim: task.status?.name ?? "未確認") }
            property("person", "担当") { Text(verbatim: task.owner?.name ?? "未設定") }
            if let delegate = task.executor?.name {
                property("arrow.turn.down.right", "委任先") { Text(verbatim: delegate) }
            }
            if let priority = task.priority, priority != 0 {
                property("chart.bar", "優先度") {
                    HStack(spacing: LAASpacing.x1) {
                        LAATaskPriorityMark(value: priority)
                        Text(verbatim: LAALinearTask.priorityLabel(priority))
                    }
                }
            }
            if let due = LAADateText.dueDay(task.dueDate) {
                property("calendar", "期限") {
                    Text(verbatim: due.label)
                        .fontWeight(due.urgent ? .semibold : .regular)
                        .foregroundStyle(due.urgent ? LAAColor.attention : LAAColor.text)
                }
            }
            if let project = task.project?.name { property("folder", "プロジェクト") { Text(verbatim: project) } }
            if let milestone = task.milestone?.name { property("flag", "マイルストーン") { Text(verbatim: milestone) } }
            if let cycle = task.cycle?.name ?? task.cycle?.number.map(String.init) {
                property("arrow.triangle.2.circlepath", "サイクル") { Text(verbatim: cycle) }
            }
            if let estimate = task.estimate { property("gauge.with.dots.needle.33percent", "見積り") { Text(verbatim: estimate.formatted(.number)) } }
            if let parent = task.parent {
                property("arrow.up.left", "親") { Text(verbatim: parent.identifier ?? parent.title ?? parent.id) }
            }
            if let labels = task.labels, !labels.isEmpty {
                property("tag", "ラベル") {
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        LAATaskMetaFlow(spacing: 6, lineSpacing: 6) {
                            ForEach(labels) { label in
                                HStack(spacing: 4) {
                                    Circle().fill(label.color.flatMap(LAATaskGenre.color(hex:)) ?? LAAColor.secondaryText)
                                        .frame(width: 7, height: 7)
                                    Text(verbatim: label.name)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(LAAColor.subtleSurface, in: Capsule())
                            }
                        }
                        if task.labelsComplete != true {
                            Text(verbatim: "ラベルは一部のみ表示しています。")
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                    }
                }
            }
            property("clock", "更新") { Text(verbatim: LAAWorkPresentation.date(task.updatedAt)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .workCard()
        .accessibilityIdentifier("work.task.detail.properties")
    }

    private func property<Value: View>(_ symbol: String, _ label: String, @ViewBuilder value: () -> Value) -> some View {
        GridRow {
            Label { Text(verbatim: label) } icon: {
                Image(systemName: symbol).foregroundStyle(LAAColor.secondaryText).frame(width: 18)
            }
            .laaTextStyle(.secondary)
            .foregroundStyle(LAAColor.secondaryText)
            .gridColumnAlignment(.leading)
            value()
                .laaTextStyle(.body)
                .foregroundStyle(LAAColor.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func genreChip(_ genre: LAATaskGenre) -> some View {
        HStack(spacing: 4) {
            Image(systemName: genre.symbol).font(.system(size: 10, weight: .semibold))
            Text(verbatim: genre.title)
        }
        .laaTextStyle(.secondary).fontWeight(.medium)
        .foregroundStyle(genre.tint)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(genre.tint.opacity(0.12), in: Capsule())
        .accessibilityLabel(Text(verbatim: "ジャンル \(genre.title)"))
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
