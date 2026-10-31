#if LAA_BUILD
import SwiftUI

private struct BrainNoteLoadKey: Equatable { let reference: LAABrainReference; let revision: Int; let isLocal: Bool }

struct LAABrainNoteView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let reference: LAABrainReference
    let files: [LAABrainFile]
    @ObservedObject var local: LAABrainLocalVault
    let isLocal: Bool
    let index: LAABrainIndex?
    let isPinned: Bool
    let togglePin: () -> Void
    @Binding var path: [LAABrainRoute]
    @State private var note: LAABrainNote?
    @State private var error: LAABridgeError?
    @State private var localError: String?
    @State private var loading = true
    @State private var raw = false
    @State private var showQuickSwitch = false
    @State private var editorRoot: URL?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                LAAColor.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: LAASpacing.x4) {
                        Text(verbatim: reference.path).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        if LAABrainSaveCoordinator.isConflictCopy(reference.path) {
                            Text(verbatim: "競合コピー").foregroundStyle(LAAColor.attention)
                                .accessibilityIdentifier("laa.brain.conflictCopy")
                            if let original = LAABrainSaveCoordinator.conflictOriginalPath(reference.path),
                               let other = files.first(where: { $0.path == original }) {
                                Text(verbatim: "このコピーと元のノートを見比べ、残す内容を選んでください。")
                                    .laaTextStyle(.secondary)
                                Button("元のノートを開く") {
                                    path.append(.note(LAABrainReference(file: other, includeInbox: reference.inbox)))
                                }.accessibilityIdentifier("laa.brain.conflictOriginal")
                            } else {
                                Text(verbatim: "元のノートを一覧から開き、残す内容を見比べてください。")
                                    .laaTextStyle(.secondary)
                            }
                        }
                        if loading { ProgressView().accessibilityLabel(Text(verbatim: "読み込み中")) }
                        else if let localError {
                            Text(verbatim: localError).foregroundStyle(LAAColor.attention)
                            Button { Task { await load() } } label: { Text(verbatim: LAACopy.Brain.retry) }
                        } else if let error {
                            Text(verbatim: error.japaneseText).foregroundStyle(LAAColor.attention)
                            Button { Task { await load() } } label: { Text(verbatim: LAACopy.Brain.retry) }
                        } else if let note {
                            if raw {
                                Text(verbatim: note.text).laaTextStyle(.body).monospaced()
                                    .textSelection(.enabled).accessibilityIdentifier("laa.brain.raw")
                            } else {
                                if let anchor = reference.anchor, !anchor.isEmpty, LAABrainDocument(note.text).section(anchor) == nil {
                                    Text(verbatim: "Heading not found: \(anchor)").laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                                }
                                LAABrainRenderedDocument(note: note, files: files, local: local, isLocal: isLocal,
                                                         visited: [note.path], depth: 0, open: { path.append(.note($0)) })
                                if isLocal, let index {
                                    relatedLinks(LAACopy.Brain.links, files: index.outgoing(from: note.path, files: files))
                                    relatedLinks(LAACopy.Brain.backlinks, files: index.backlinks(to: note.path, files: files))
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
                    Button { showQuickSwitch = true } label: { Image(systemName: "doc.text.magnifyingglass") }
                        .accessibilityLabel(Text(verbatim: "Switch note"))
                        .accessibilityIdentifier("laa.brain.quickSwitch")
                }
                if isLocal && LAABrainEditingGate.enabled && note != nil && !LAABrainSaveCoordinator.isConflictCopy(reference.path) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { editorRoot = try? local.snapshot() } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel(Text(verbatim: "Edit note"))
                            .accessibilityIdentifier("laa.brain.edit")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: togglePin) { Image(systemName: isPinned ? "pin.fill" : "pin") }
                        .accessibilityLabel(Text(verbatim: isPinned ? LAACopy.Brain.unpin : LAACopy.Brain.pin))
                        .accessibilityIdentifier("laa.brain.pin")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { raw.toggle() } label: { Text(verbatim: raw ? LAACopy.Brain.formatted : LAACopy.Brain.raw) }
                        .accessibilityIdentifier("laa.brain.rawToggle")
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "laabrain", url.host == "note",
                   let file = files.first(where: { $0.id == String(url.path.dropFirst()) }) {
                    let anchor = url.fragment?.removingPercentEncoding ?? url.fragment
                    if file.path == reference.path, let anchor, !anchor.isEmpty {
                        proxy.scrollTo(LAABrainDocument.anchorID(path: file.path, title: anchor), anchor: .top)
                    } else {
                        path.append(.note(LAABrainReference(file: file, includeInbox: reference.inbox, anchor: anchor)))
                    }
                    return .handled
                }
                if url.scheme == "laabrain", url.host == "footnote",
                   let file = files.first(where: { $0.id == String(url.path.dropFirst()) }),
                   let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
                    proxy.scrollTo(LAABrainDocument.footnoteID(path: file.path, id: id), anchor: .top)
                    return .handled
                }
                if url.scheme == nil,
                   let file = LAABrainPaths.resolve(url.relativeString, currentPath: reference.path, files: files) {
                    path.append(.note(LAABrainReference(file: file, includeInbox: reference.inbox, anchor: url.fragment)))
                    return .handled
                }
                return url.scheme == nil || url.scheme == "laabrain" ? .discarded : .systemAction
            })
            .onChange(of: loading) { _, isLoading in
                if !isLoading, let anchor = reference.anchor, !anchor.isEmpty {
                    DispatchQueue.main.async { proxy.scrollTo(LAABrainDocument.anchorID(path: reference.path, title: anchor), anchor: .top) }
                }
            }
            .sheet(isPresented: $showQuickSwitch) {
                LAABrainQuickSwitch(files: files) { file in
                    showQuickSwitch = false
                    path.append(.note(LAABrainReference(file: file, includeInbox: reference.inbox)))
                }
            }
            .sheet(isPresented: Binding(get: { editorRoot != nil }, set: { if !$0 { editorRoot = nil } })) {
                if let editorRoot {
                    LAABrainSaveEditor(root: editorRoot, path: reference.path) { Task { await load() } }
                }
            }
            .task(id: BrainNoteLoadKey(reference: reference, revision: isLocal ? local.revision : 0, isLocal: isLocal)) { await load() }
        }
    }

    @ViewBuilder private func relatedLinks(_ title: String, files: [LAABrainFile]) -> some View {
        if !files.isEmpty {
            Text(verbatim: title).laaTextStyle(.section).fontWeight(.semibold)
                .foregroundStyle(LAAColor.secondaryText).padding(.top, LAASpacing.x4)
            ForEach(files) { file in
                Button { path.append(.note(LAABrainReference(file: file, includeInbox: reference.inbox))) } label: {
                    Label { Text(verbatim: file.path) } icon: { Image(systemName: "doc.text") }
                }.frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
            }
        }
    }

    @MainActor private func load() async {
        loading = true; error = nil; localError = nil; note = nil
        if isLocal {
            do {
                let root = try local.snapshot()
                let path = reference.path
                let result = try await Task.detached(priority: .userInitiated) { try LAABrainVaultIO.note(root: root, path: path) }.value
                try Task.checkCancellation()
                note = result; loading = false
            } catch is CancellationError { return }
            catch { localError = (error as? LAABrainVaultError)?.message ?? LAABrainVaultError.unreadable.message; loading = false }
            return
        }
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

private struct LAABrainQuickSwitch: View {
    @Environment(\.dismiss) private var dismiss
    let files: [LAABrainFile]
    let open: (LAABrainFile) -> Void
    @State private var query = ""

    private var matches: [LAABrainFile] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return files.filter { term.isEmpty || $0.path.localizedStandardContains(term) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(matches) { file in
                Button { open(file) } label: {
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        Text(verbatim: file.title).foregroundStyle(LAAColor.text)
                        Text(verbatim: file.path).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                }.accessibilityIdentifier("laa.brain.quickSwitch.note")
            }
            .searchable(text: $query, prompt: "Find a note")
            .navigationTitle("Switch note")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
#endif
