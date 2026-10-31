#if LAA_BUILD
import SwiftUI

// Retained for the existing agent-source fixture contract.
struct LAAWorkTaskDetailResponse: Decodable { let task: LAAWorkTask }

struct LAAWorkTaskDetailView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let id: String
    @State private var task: LAAPersonalTask?
    @State private var viewerId: String?
    @State private var error: String?
    @State private var showEdit = false

    init(id: String, drafts: ComposerDraftStore) { self.id = id; self.drafts = drafts }

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
                        Text(verbatim: task.sourceId).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
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
                        if let description = task.description, !description.isEmpty {
                            MarkdownText(source: description, foregroundStyle: LAAColor.text).workCard()
                        }
                        if let raw = task.url, let url = URL(string: raw), url.scheme?.lowercased() == "https" {
                            Link(LAACopy.WorkTab.openLinear, destination: url).buttonStyle(.bordered)
                        }
                    } else if error == nil { ProgressView().accessibilityLabel(Text(verbatim: "読み込み中")) }
                }.padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4)
                    .frame(maxWidth: 720, alignment: .leading)
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
        .task { await load() }
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
