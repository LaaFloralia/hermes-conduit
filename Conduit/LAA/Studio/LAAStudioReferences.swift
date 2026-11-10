#if LAA_BUILD
import SwiftUI

struct LAAStudioReferencePicker: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let selected: (String) -> Void
    @StateObject private var browser = LAADriveBrowseController()
    @State private var search = ""
    @State private var folder: String?
    @State private var parents: [String?] = []
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    if folder != nil {
                        Button("戻る") { folder = parents.isEmpty ? nil : parents.removeLast(); Task { await load() } }.frame(minHeight: 44)
                    }
                    ForEach(browser.items) { entry in
                        Button {
                            if entry.item.kind == "folder" {
                                parents.append(folder); folder = entry.id; Task { await load() }
                            } else {
                                let link = entry.safeWebViewURL?.absoluteString ?? "https://drive.google.com/file/d/\(entry.id)/view"
                                selected(entry.item.name + "\n" + link); dismiss()
                            }
                        } label: {
                            Label(entry.item.name, systemImage: entry.item.kind == "folder" ? "folder" : "doc")
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    if browser.cursor != nil { Button("さらに表示") { Task { await browser.loadMore(using: page) } }.frame(minHeight: 44) }
                    if browser.error != nil { LAAStudioConnectionLine(message: "Driveを読み込めません") { Task { await load() } } }
                    if browser.loading && browser.items.isEmpty { LAAStudioSkeleton() }
                }.padding(LAASpacing.horizontal)
            }.background(LAAColor.background).searchable(text: $search, prompt: "検索")
                .onSubmit(of: .search) { Task { await load() } }
                .navigationTitle("参考を添付").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
                .task(id: bridge.revision) { browser.invalidate(); folder = nil; parents = []; await load() }
        }.tint(LAAColor.link)
    }
    @MainActor private func page(_ query: LAADriveBrowseQuery) async throws -> LAADriveListingPage {
        try await LAADriveData.listingPage(query, bridge: bridge)
    }
    @MainActor private func load() async {
        await browser.reload(.init(section: .my, folderID: folder, search: search), using: page)
    }
}
#endif
