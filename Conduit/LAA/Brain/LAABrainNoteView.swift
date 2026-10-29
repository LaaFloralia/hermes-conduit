#if LAA_BUILD
import SwiftUI

struct LAABrainNoteView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let reference: LAABrainReference
    let files: [LAABrainFile]
    @Binding var path: [LAABrainRoute]
    @State private var note: LAABrainNote?
    @State private var error: LAABridgeError?
    @State private var loading = true
    @State private var raw = false

    var body: some View {
        ZStack {
            LAAColors.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: reference.path).font(.footnote).foregroundStyle(LAAColors.muted)
                    if loading { ProgressView().accessibilityLabel(Text(verbatim: "読み込み中")) }
                    else if let error {
                        Text(verbatim: error.japaneseText).foregroundStyle(LAAColors.plum)
                        Button { Task { await load() } } label: { Text(verbatim: "再読み込み") }
                    } else if let note {
                        if raw {
                            Text(verbatim: note.text).font(.system(.body, design: .monospaced))
                                .textSelection(.enabled).accessibilityIdentifier("laa.brain.raw")
                        } else {
                            let document = LAABrainDocument(note.text)
                            if let frontmatter = document.frontmatter {
                                DisclosureGroup {
                                    Text(verbatim: frontmatter).font(.system(.footnote, design: .monospaced))
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                } label: { Text(verbatim: "メタデータ（frontmatter）") }
                            }
                            ForEach(Array(document.parts(currentPath: note.path, files: files).enumerated()), id: \.offset) { _, part in
                                switch part {
                                case .markdown(let source):
                                    // The shared Markdown cache keys its two supported
                                    // text styles by surface; use its default style.
                                    MarkdownText(source: source)
                                case .raw(let source):
                                    Text(verbatim: source).font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                case .image(let source):
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label { Text(verbatim: "画像はこの接続では表示できません") } icon: { Image(systemName: "photo") }
                                            .foregroundStyle(LAAColors.muted)
                                        Text(verbatim: source).font(.system(.footnote, design: .monospaced))
                                            .textSelection(.enabled)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                .padding(16).frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(LAAColors.ink)
            }
        }
        .navigationTitle(Text(verbatim: reference.path.split(separator: "/").last.map(String.init) ?? reference.path))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { if !path.isEmpty { path.removeLast() } } label: {
                    Label { Text(verbatim: "戻る") } icon: { Image(systemName: "chevron.left") }
                }.accessibilityIdentifier("laa.brain.back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { raw.toggle() } label: { Text(verbatim: raw ? "表示" : "原文") }
                    .accessibilityIdentifier("laa.brain.rawToggle")
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "laabrain", url.host == "note",
               let file = files.first(where: { $0.id == String(url.path.dropFirst()) }) {
                path.append(.note(LAABrainReference(file: file, includeInbox: reference.inbox)))
                return .handled
            }
            if url.scheme == nil,
               let file = LAABrainPaths.resolve(url.relativeString, currentPath: reference.path, files: files) {
                path.append(.note(LAABrainReference(file: file, includeInbox: reference.inbox)))
                return .handled
            }
            return url.scheme == nil || url.scheme == "laabrain" ? .discarded : .systemAction
        })
        .task(id: reference) { await load() }
    }

    @MainActor private func load() async {
        loading = true; error = nil; note = nil
        guard let route = LAABrainPaths.request("/v1/brain/files/" + reference.id, includeInbox: reference.inbox) else {
            error = .invalidResponse; loading = false; return
        }
        do {
            let result: LAABrainNote = try await LAABrainData.read(route, bridge: bridge)
            try Task.checkCancellation()
            note = result; loading = false
        } catch is CancellationError { return }
        catch let failure as LAABridgeError { error = failure; loading = false }
        catch { self.error = .invalidResponse; loading = false }
    }
}
#endif
