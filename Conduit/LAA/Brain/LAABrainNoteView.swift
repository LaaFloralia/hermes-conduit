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
            LAAColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    Text(verbatim: reference.path).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    if loading { ProgressView().accessibilityLabel(Text(verbatim: "読み込み中")) }
                    else if let error {
                        Text(verbatim: error.japaneseText).foregroundStyle(LAAColor.attention)
                        Button { Task { await load() } } label: { Text(verbatim: LAACopy.Brain.retry) }
                    } else if let note {
                        if raw {
                            Text(verbatim: note.text).laaTextStyle(.body).monospaced()
                                .textSelection(.enabled).accessibilityIdentifier("laa.brain.raw")
                        } else {
                            let document = LAABrainDocument(note.text)
                            if let frontmatter = document.frontmatter {
                                DisclosureGroup {
                                    Text(verbatim: frontmatter).laaTextStyle(.secondary).monospaced()
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                } label: { Text(verbatim: LAACopy.Brain.frontmatter) }
                            }
                            ForEach(Array(document.parts(currentPath: note.path, files: files).enumerated()), id: \.offset) { _, part in
                                switch part {
                                case .markdown(let source):
                                    // The shared Markdown cache keys its two supported
                                    // text styles by surface; use its default style.
                                    MarkdownText(source: source)
                                case .raw(let source):
                                    Text(verbatim: source).laaTextStyle(.body).monospaced()
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                case .image(let source):
                                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                                        Label { Text(verbatim: "画像はこの接続では表示できません") } icon: { Image(systemName: "photo") }
                                            .foregroundStyle(LAAColor.secondaryText)
                                        Text(verbatim: source).laaTextStyle(.secondary).monospaced()
                                            .textSelection(.enabled)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                .padding(LAASpacing.horizontal)
                .frame(maxWidth: 720, alignment: .leading)
                .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                .padding(.horizontal, LAASpacing.horizontal)
                .frame(maxWidth: .infinity, alignment: .center)
                .foregroundStyle(LAAColor.text)
            }
        }
        .navigationTitle(Text(verbatim: reference.path.split(separator: "/").last.map(String.init) ?? reference.path))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { if !path.isEmpty { path.removeLast() } } label: {
                    Label { Text(verbatim: LAACopy.Brain.back) } icon: { Image(systemName: "chevron.left") }
                }.accessibilityIdentifier("laa.brain.back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { raw.toggle() } label: { Text(verbatim: raw ? LAACopy.Brain.formatted : LAACopy.Brain.raw) }
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
