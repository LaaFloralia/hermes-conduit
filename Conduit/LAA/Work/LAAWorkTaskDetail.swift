#if LAA_BUILD
import SwiftUI

struct LAAWorkTaskDetailResponse: Decodable {
    let task: LAAWorkTask
}

struct LAAWorkTaskDetailView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let id: String
    @State private var task: LAAWorkTask?
    @State private var error: String?

    var body: some View {
        ZStack {
            LAAColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(LAAColor.attention)
                        Button(LAACopy.WorkTab.retry) { Task { await load() } }
                    } else if let task {
                        Text(verbatim: task.title).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                        Text(verbatim: "Linearのタスク · 閲覧のみ").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        VStack(alignment: .leading, spacing: LAASpacing.x2) {
                            Text(verbatim: "状態: \(task.status?.name ?? "未確認")")
                            Text(verbatim: "担当: \(task.owner?.name ?? "未設定")")
                            Text(verbatim: "実行: \(task.executor?.name ?? "未設定")")
                            Text(verbatim: "プロジェクト: \(task.project?.name ?? "未設定")")
                            Text(verbatim: "更新: \(LAAWorkPresentation.date(task.updatedAt))")
                        }.workCard()
                        if let description = task.description, !description.isEmpty {
                            MarkdownText(source: description, foregroundStyle: LAAColor.text).workCard()
                        }
                        if let raw = task.url, let url = URL(string: raw), url.scheme?.lowercased() == "https" {
                            Link(LAACopy.WorkTab.openLinear, destination: url).buttonStyle(.bordered)
                        }
                    } else {
                        ProgressView().accessibilityLabel(Text(verbatim: "読み込み中"))
                    }
                }.padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4).frame(maxWidth: 720, alignment: .leading)
            }
        }
        .navigationTitle(Text(verbatim: LAACopy.WorkTab.task))
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await load() }
    }

    private func load() async {
        do {
            let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            let detail: LAAWorkTaskDetailResponse = try await bridge.read("/v1/tasks/\(safe)")
            task = detail.task
            error = nil
        } catch is CancellationError {
        } catch let failure as LAABridgeError { error = failure.japaneseText }
        catch { self.error = "タスクを読み取れませんでした。" }
    }
}
#endif
