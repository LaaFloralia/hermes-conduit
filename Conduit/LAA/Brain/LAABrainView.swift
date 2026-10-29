#if LAA_BUILD
import SwiftUI

private struct BrainLoadKey: Equatable { let revision: Int; let inbox: Bool }
private struct BrainSearchKey: Equatable { let revision: Int; let inbox: Bool; let query: String }

struct LAABrainPending: Codable {
    let request: LAABrainCreateBody
    let bytes: Data
    let keyValue: String
    let deviceID: String
}

struct LAABrainView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let onRequestSettings: () -> Void
    @State private var path: [LAABrainRoute] = []
    @State private var files: [LAABrainFile] = []
    @State private var hits: [LAABrainHit] = []
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var mode = 0
    @State private var includeInbox = false
    @State private var isLoading = false
    @State private var isSearching = false
    @State private var listError: LAABridgeError?
    @State private var searchError: LAABridgeError?
    @State private var showPairing = false
    @State private var showCreate = false
    @State private var pending: LAABrainPending?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                LAAColors.paper.ignoresSafeArea()
                List {
                    Section {
                        Text(verbatim: "Brain").font(LAAFont.largeHeading)
                            .foregroundStyle(LAAColors.ink).accessibilityAddTraits(.isHeader)
                        if !LAABrainData.available(bridge) {
                            connectionView
                        } else {
                            HStack {
                                Image(systemName: "magnifyingglass").foregroundStyle(LAAColors.muted)
                                TextField(text: $query) { Text(verbatim: "Brainを検索") }
                                    .focused($searchFocused)
                                    .submitLabel(.search)
                                    .onSubmit { searchFocused = false }
                                    .accessibilityIdentifier("laa.brain.search")
                                if !query.isEmpty {
                                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                        .accessibilityLabel(Text(verbatim: "検索を消去"))
                                }
                            }
                            Picker(selection: $mode) {
                                Text(verbatim: "最近").tag(0)
                                Text(verbatim: "フォルダ").tag(1)
                            } label: { Text(verbatim: "表示") }
                            .pickerStyle(.segmented)
                            Toggle(isOn: $includeInbox) { Text(verbatim: "Inboxを含める") }
                                .accessibilityIdentifier("laa.brain.inbox")
                            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                searchResults
                            } else if let listError {
                                failure(listError)
                            } else if isLoading && files.isEmpty {
                                ProgressView().accessibilityLabel(Text(verbatim: "読み込み中"))
                            } else if files.isEmpty {
                                Text(verbatim: "表示できるメモはありません。")
                                    .foregroundStyle(LAAColors.muted)
                            } else if mode == 0 {
                                recent
                            } else {
                                folderContents("")
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
            .navigationTitle(Text(verbatim: "Brain"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if LAABrainData.available(bridge) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showCreate = true } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel(Text(verbatim: "新規メモ"))
                            .accessibilityIdentifier("laa.brain.create")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onRequestSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel(Text(verbatim: LAACopy.settings))
                }
            }
            .navigationDestination(for: LAABrainRoute.self) { route in
                switch route {
                case .folder(let folder):
                    ZStack {
                        LAAColors.paper.ignoresSafeArea()
                        List { folderContents(folder).listRowBackground(Color.clear) }
                            .listStyle(.plain).scrollContentBackground(.hidden)
                    }
                    .navigationTitle(Text(verbatim: folder.split(separator: "/").last.map(String.init) ?? folder))
                    .navigationBarBackButtonHidden(true)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { if !path.isEmpty { path.removeLast() } } label: {
                                Label { Text(verbatim: "戻る") } icon: { Image(systemName: "chevron.left") }
                            }.accessibilityIdentifier("laa.brain.back")
                        }
                    }
                case .note(let reference):
                    LAABrainNoteView(reference: reference, files: files, path: $path)
                        .toolbar(.hidden, for: .tabBar)
                }
            }
        }
        .tint(LAAColors.teal)
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .sheet(isPresented: $showCreate) {
            LAABrainCreateView(pending: $pending) { created in
                showCreate = false
                // Creation is explicitly in Inbox; opening it is an explicit
                // request for that area, independent of the list switch.
                path.append(.note(LAABrainReference(path: created.path, includeInbox: true)))
            }.environmentObject(bridge)
        }
        .task(id: BrainLoadKey(revision: bridge.revision, inbox: includeInbox)) { await load() }
        .task(id: BrainSearchKey(revision: bridge.revision, inbox: includeInbox, query: query)) { await search() }
    }

    private var connectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: bridge.status == .keychainError ? LAABridgeError.keychain.japaneseText :
                 bridge.status == .revoked || bridge.status == .unauthorized ?
                 "この端末の接続が無効になりました。新しいコードで接続してください。" : LAACopy.bridgeNotPairedBody)
            if bridge.status != .keychainError {
                Button { showPairing = true } label: { Text(verbatim: "Macに接続する") }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("laa.bridge.openPairing")
            }
        }
    }

    private var recent: some View {
        ForEach(files.sorted { $0.modifiedAt > $1.modifiedAt }) { file in noteLink(file) }
    }

    @ViewBuilder private func folderContents(_ folder: String) -> some View {
        let folders = LAABrainPaths.folders(in: files, parent: folder)
        ForEach(folders, id: \.self) { name in
            let child = folder.isEmpty ? name : folder + "/" + name
            NavigationLink(value: LAABrainRoute.folder(child)) {
                Label { Text(verbatim: name) } icon: { Image(systemName: "folder") }
            }
        }
        ForEach(files.filter { $0.folder == folder }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { file in
            noteLink(file)
        }
    }

    private func noteLink(_ file: LAABrainFile) -> some View {
        NavigationLink(value: LAABrainRoute.note(LAABrainReference(file: file, includeInbox: includeInbox))) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: file.title).foregroundStyle(LAAColors.ink)
                Text(verbatim: file.path).font(.footnote).foregroundStyle(LAAColors.muted)
                if file.unreadable != nil { Text(verbatim: "本文を読み込めません").font(.caption).foregroundStyle(LAAColors.plum) }
            }
        }
        .accessibilityIdentifier("laa.brain.note")
    }

    @ViewBuilder private var searchResults: some View {
        if let searchError { failure(searchError) }
        else if isSearching { ProgressView().accessibilityLabel(Text(verbatim: "検索中")) }
        else if hits.isEmpty { Text(verbatim: "検索結果はありません。 ").foregroundStyle(LAAColors.muted) }
        else {
            Text(verbatim: "検索結果（最大10件）").font(.footnote).foregroundStyle(LAAColors.muted)
            ForEach(hits) { hit in
                NavigationLink(value: LAABrainRoute.note(LAABrainReference(path: hit.path, includeInbox: includeInbox))) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: hit.path).font(.headline).foregroundStyle(LAAColors.ink)
                        if !hit.section.isEmpty { Text(verbatim: hit.section).font(.caption).foregroundStyle(LAAColors.muted) }
                        Text(verbatim: hit.text).font(.subheadline).foregroundStyle(LAAColors.muted).lineLimit(4)
                    }
                }.accessibilityIdentifier("laa.brain.searchResult")
            }
        }
    }

    private func failure(_ error: LAABridgeError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text(verbatim: error.japaneseText) } icon: { Image(systemName: "exclamationmark.triangle") }
                .foregroundStyle(LAAColors.plum)
            Button { Task { if query.isEmpty { await load() } else { await search() } } } label: { Text(verbatim: "再読み込み") }
        }
    }

    @MainActor private func load() async {
        guard LAABrainData.available(bridge) else { files = []; listError = nil; isLoading = false; return }
        let inbox = includeInbox
        files = []; listError = nil; isLoading = true
        do {
            var result: [LAABrainFile] = []
            var cursor: String?
            var seen = Set<String>()
            repeat {
                var params = [URLQueryItem(name: "limit", value: "200")]
                if let cursor { params.append(URLQueryItem(name: "cursor", value: cursor)) }
                guard let route = LAABrainPaths.request("/v1/brain/files", items: params, includeInbox: inbox) else { throw LAABridgeError.invalidResponse }
                let page: LAABrainPage = try await LAABrainData.read(route, bridge: bridge)
                try Task.checkCancellation()
                result.append(contentsOf: page.items)
                cursor = page.nextCursor
                if let cursor, !seen.insert(cursor).inserted || seen.count > 100 { throw LAABridgeError.invalidResponse }
            } while cursor != nil
            guard includeInbox == inbox else { return }
            files = result; isLoading = false
        } catch is CancellationError { return }
        catch let error as LAABridgeError { listError = error; isLoading = false }
        catch { listError = .invalidResponse; isLoading = false }
    }

    @MainActor private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LAABrainData.available(bridge), !term.isEmpty else { hits = []; searchError = nil; isSearching = false; return }
        let inbox = includeInbox
        hits = []; searchError = nil; isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(350))
            guard let route = LAABrainPaths.request("/v1/brain/search", items: [URLQueryItem(name: "q", value: term), URLQueryItem(name: "k", value: "10")], includeInbox: inbox) else { throw LAABridgeError.invalidResponse }
            let result: LAABrainSearch = try await LAABrainData.read(route, bridge: bridge)
            try Task.checkCancellation()
            guard term == query.trimmingCharacters(in: .whitespacesAndNewlines), inbox == includeInbox else { return }
            hits = result.results; isSearching = false
        } catch is CancellationError { return }
        catch let error as LAABridgeError { searchError = error; isSearching = false }
        catch { searchError = .invalidResponse; isSearching = false }
    }
}
#endif
