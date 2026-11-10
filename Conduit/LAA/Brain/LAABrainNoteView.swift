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
    @Binding var autoEditPath: String?
    @Binding var editorIsOpen: Bool
    var readingPositions: LAABrainReadingPositions
    /// The Mac detail column has no list to go back to and takes the window
    /// title from the shell.
    var showsBackButton = true
    var usesNavigationTitle = true
    /// The Mac detail column paints the whole column and narrows only this
    /// card, so no second colour shows down its sides.
    var contentMaxWidth: CGFloat? = nil
    /// Leaves this note once it has moved or gone to the trash: the phone
    /// pops it, the Mac detail column clears its selection.
    var leave: (() -> Void)? = nil
    @State private var note: LAABrainNote?
    @State private var error: LAABridgeError?
    @State private var localError: String?
    @State private var loading = true
    @State private var raw = false
    @State private var showQuickSwitch = false
    @State private var showManage = false
    @State private var managedNote: LAABrainNote?
    @State private var showInfo = false
    @State private var autoFocusRequested = false

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if isLocal, let root = try? local.snapshot(), !LAABrainSaveCoordinator.isConflictCopy(reference.path) {
                    LAABrainSaveEditor(root: root, path: reference.path,
                        autoFocus: autoFocusRequested, inline: true,
                        showsBackButton: showsBackButton, isPinned: isPinned, togglePin: togglePin,
                        leave: { if let leave { leave() } else if !path.isEmpty { path.removeLast() } },
                        manage: { managedNote = note; editorIsOpen = true; showManage = true },
                        readingPositions: readingPositions,
                        onOpenLink: { target in openLink(target) },
                        attachments: { source in AnyView(attachmentPreviews(source)) }) { Task { await load() } }
                        .id(root.absoluteString + reference.path)
                } else {
            ZStack {
                LAAColor.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: LAASpacing.x4) {
                        Text(verbatim: URL(fileURLWithPath: reference.path).deletingPathExtension().lastPathComponent)
                            .font(.custom("Georgia", size: 34, relativeTo: .largeTitle))
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
                            Text(verbatim: error == .forbidden ? LAACopy.Brain.ownerPermissionRequired : error.japaneseText).foregroundStyle(LAAColor.attention)
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
                                                         visited: [note.path], depth: 0, open: { path.append(.note($0)) },
                                                         lookup: LAABrainPathLookup(files: files))
                                if isLocal, let index {
                                    relatedLinks(LAACopy.Brain.links, files: index.outgoing(from: note.path, files: files))
                                    relatedLinks(LAACopy.Brain.backlinks, files: index.backlinks(to: note.path, files: files))
                                }
                            }
                        }
                    }
                    .padding(LAASpacing.horizontal)
                    .frame(maxWidth: contentMaxWidth ?? 720, alignment: .leading)
                    .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                    .padding(.horizontal, LAASpacing.horizontal)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .foregroundStyle(LAAColor.text)
                }
                .modifier(LAABrainReadingPosition(store: readingPositions,
                          key: ((try? local.snapshot())?.absoluteString ?? "bridge") + reference.path,
                          loaded: note != nil, hasAnchor: reference.anchor != nil))
            }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if !isLocal || LAABrainSaveCoordinator.isConflictCopy(reference.path) {
                    if showsBackButton {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { if !path.isEmpty { path.removeLast() } } label: { Image(systemName: "chevron.left") }
                                .accessibilityLabel("戻る").accessibilityIdentifier("laa.brain.back")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("文書内検索") { showQuickSwitch = true }
                            Button(isPinned ? "ピン留めを外す" : "ピン留めする", action: togglePin)
                            Button(raw ? "本文を表示" : "Markdownを表示") { raw.toggle() }.accessibilityIdentifier("laa.brain.rawToggle")
                            Button("情報") { showInfo = true }
                        } label: { Image(systemName: "ellipsis") }
                            .accessibilityLabel("ノートのメニュー").accessibilityIdentifier("laa.brain.menu")
                    }
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
            .sheet(isPresented: $showManage, onDismiss: { editorIsOpen = false; managedNote = nil }) {
                if let managedNote, let root = try? local.snapshot() {
                    LAABrainManageNoteView(root: root, rootName: local.location?.rawValue ?? root.lastPathComponent,
                                           note: managedNote) { destination in
                        showManage = false; editorIsOpen = false
                        if let leave { leave() } else if !path.isEmpty { path.removeLast() }
                        if !destination.hasPrefix(".trash/") {
                            path.append(.note(LAABrainReference(path: destination, includeInbox: true)))
                        }
                    }
                }
            }
            .sheet(isPresented: $showQuickSwitch) {
                LAABrainQuickSwitch(files: files) { file in
                    showQuickSwitch = false
                    path.append(.note(LAABrainReference(file: file, includeInbox: reference.inbox)))
                }
            }
            .sheet(isPresented: $showInfo) {
                NavigationStack {
                    List { LabeledContent("場所", value: reference.path)
                        if let metadata = note.map({ LAABrainDocument($0.text).frontmatter }) ?? nil {
                            Text(verbatim: metadata).textSelection(.enabled)
                        }
                    }.navigationTitle("情報")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showInfo = false } } }
                }
            }
            .task(id: BrainNoteLoadKey(reference: reference, revision: isLocal ? local.revision : 0, isLocal: isLocal)) { await load() }
            .onAppear { if autoEditPath == reference.path { autoFocusRequested = true; autoEditPath = nil } }
        }
    }

    @ViewBuilder private func attachmentPreviews(_ source: String) -> some View {
        let images = LAABrainDocument(source).parts(currentPath: reference.path, files: files).compactMap { part -> String? in
            if case .image(let value) = part { return value }; return nil
        }
        ForEach(Array(images.enumerated()), id: \.offset) { _, image in
            LAABrainEmbedView(source: image, currentPath: reference.path, files: files, local: local,
                              isLocal: true, visited: [reference.path], depth: 0, maxPixelSize: 1600,
                              open: { path.append(.note($0)) }, lookup: LAABrainPathLookup(files: files))
        }
    }

    private func openLink(_ target: String) {
        let rawTarget = target.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        if let file = LAABrainPaths.resolve(rawTarget, currentPath: reference.path, files: files) {
            let pieces = rawTarget.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            path.append(.note(LAABrainReference(file: file, includeInbox: reference.inbox,
                                              anchor: pieces.count > 1 ? String(pieces[1]) : nil)))
        } else if let url = URL(string: rawTarget), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
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
        if note?.path != reference.path { loading = true; note = nil }
        error = nil; localError = nil
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
            .searchable(text: $query, prompt: "ノートを検索")
            .navigationTitle("ノートを切り替える")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}
#endif
