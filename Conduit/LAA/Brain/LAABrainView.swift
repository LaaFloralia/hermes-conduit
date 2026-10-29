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
    @State private var showAllRecent = false
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
                LAAColor.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: LAASpacing.section) {
                        heading
                        if LAABrainData.available(bridge) {
                            browser
                        } else {
                            connectionView
                        }
                    }
                    .padding(.horizontal, LAASpacing.horizontal)
                    .padding(.vertical, LAASpacing.x4)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .refreshable { await load() }
            }
            .navigationTitle(Text(verbatim: LAACopy.Brain.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if LAABrainData.available(bridge) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showCreate = true } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel(Text(verbatim: LAACopy.Brain.newNote))
                            .accessibilityIdentifier("laa.brain.create")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onRequestSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel(Text(verbatim: LAACopy.Brain.settings))
                }
            }
            .navigationDestination(for: LAABrainRoute.self) { route in
                switch route {
                case .folder(let folder):
                    ZStack {
                        LAAColor.background.ignoresSafeArea()
                        ScrollView {
                            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                                folderContents(folder)
                            }
                            .padding(LAASpacing.horizontal)
                            .frame(maxWidth: 720, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .navigationTitle(Text(verbatim: folder.split(separator: "/").last.map(String.init) ?? folder))
                    .navigationBarBackButtonHidden(true)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { if !path.isEmpty { path.removeLast() } } label: {
                                Label { Text(verbatim: LAACopy.Brain.back) } icon: { Image(systemName: "chevron.left") }
                            }.accessibilityIdentifier("laa.brain.back")
                        }
                    }
                case .note(let reference):
                    LAABrainNoteView(reference: reference, files: files, path: $path)
                        .toolbar(.hidden, for: .tabBar)
                }
            }
        }
        .tint(LAAColor.link)
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .sheet(isPresented: $showCreate) {
            LAABrainCreateView(pending: $pending) { created in
                showCreate = false
                path.append(.note(LAABrainReference(path: created.path, includeInbox: true)))
            }.environmentObject(bridge)
        }
        .task(id: BrainLoadKey(revision: bridge.revision, inbox: includeInbox)) { await load() }
        .task(id: BrainSearchKey(revision: bridge.revision, inbox: includeInbox, query: query)) { await search() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: "LAA").laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.link)
            Text(verbatim: LAACopy.Brain.title).font(LAAType.screenTitle)
                .foregroundStyle(LAAColor.text).accessibilityAddTraits(.isHeader)
            Text(verbatim: LAACopy.Brain.subtitle).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            HStack(spacing: LAASpacing.x3) {
                Image(systemName: "magnifyingglass").foregroundStyle(LAAColor.secondaryText)
                TextField(text: $query) { Text(verbatim: LAACopy.Brain.search) }
                    .focused($searchFocused).submitLabel(.search)
                    .onSubmit { searchFocused = false }
                    .accessibilityIdentifier("laa.brain.search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel(Text(verbatim: LAACopy.Brain.clearSearch))
                }
            }
            .laaTextStyle(.body)
            .padding(.horizontal, LAASpacing.x4)
            .frame(minHeight: LAASpacing.minimumTouchTarget)
            .background(LAAColor.subtleSurface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LAASpacing.x2) {
                    chip(LAACopy.Brain.recent, selected: mode == 0) { mode = 0 }
                    chip(LAACopy.Brain.folders, selected: mode == 1) { mode = 1 }
                    chip(LAACopy.Brain.tags, selected: false) { }
                        .disabled(true).accessibilityHint(Text(verbatim: LAACopy.Brain.tagsUnavailable))
                }
            }
            Text(verbatim: LAACopy.Brain.tagsUnavailable).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            Toggle(isOn: $includeInbox) { Text(verbatim: LAACopy.Brain.includeInbox).laaTextStyle(.secondary) }
                .accessibilityIdentifier("laa.brain.inbox")
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults
            } else if let listError {
                failure(listError)
            } else if isLoading && files.isEmpty {
                ProgressView().accessibilityLabel(Text(verbatim: LAACopy.loading))
            } else if files.isEmpty {
                Text(verbatim: "表示できるメモはありません。").foregroundStyle(LAAColor.secondaryText)
            } else if mode == 0 {
                recent
            } else {
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    sectionHeading(LAACopy.Brain.folders)
                    folderContents("")
                }
            }
        }
        .foregroundStyle(LAAColor.text)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).laaTextStyle(.secondary).fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? LAAColor.filledButtonText : LAAColor.secondaryText)
                .padding(.horizontal, LAASpacing.x4).padding(.vertical, LAASpacing.x2)
                .background(selected ? LAAColor.filledButton : LAAColor.subtleSurface,
                            in: RoundedRectangle(cornerRadius: LAARadius.selectionChip))
                .frame(minHeight: LAASpacing.minimumTouchTarget)
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(verbatim: title.uppercased()).laaTextStyle(.section).fontWeight(.semibold)
            .foregroundStyle(LAAColor.secondaryText).accessibilityAddTraits(.isHeader)
    }

    private var connectionView: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Text(verbatim: bridge.status == .keychainError ? LAABridgeError.keychain.japaneseText :
                 bridge.status == .revoked || bridge.status == .unauthorized ?
                 "この端末の接続が無効になりました。新しいコードで接続してください。" : LAACopy.bridgeNotPairedBody)
            if bridge.status != .keychainError {
                Button { showPairing = true } label: { Text(verbatim: LAACopy.Brain.connect) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("laa.bridge.openPairing")
            }
        }.laaTextStyle(.body).foregroundStyle(LAAColor.text)
    }

    private var recent: some View {
        let sorted = files.sorted { $0.modifiedAt > $1.modifiedAt }
        let roots = LAABrainPaths.folders(in: files, parent: "")
        return VStack(alignment: .leading, spacing: LAASpacing.x3) {
            HStack {
                sectionHeading(LAACopy.Brain.recent)
                Spacer()
                if sorted.count > 3 {
                    Button(showAllRecent ? LAACopy.Brain.showLess : LAACopy.Brain.seeAll) { showAllRecent.toggle() }
                        .laaTextStyle(.secondary)
                }
            }
            ForEach(Array(showAllRecent ? sorted : Array(sorted.prefix(3)))) { file in noteLink(file) }
            if !roots.isEmpty {
                HStack {
                    sectionHeading(LAACopy.Brain.folders)
                    Spacer()
                    Button(LAACopy.Brain.browse) { mode = 1 }.laaTextStyle(.secondary)
                }.padding(.top, LAASpacing.section)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: LAASpacing.x2), GridItem(.flexible())], spacing: LAASpacing.x2) {
                    ForEach(Array(roots.prefix(2)), id: \.self) { name in folderLink(name, parent: "") }
                }
            }
        }
    }

    private func folderLink(_ name: String, parent: String) -> some View {
        let child = parent.isEmpty ? name : parent + "/" + name
        return NavigationLink(value: LAABrainRoute.folder(child)) {
            HStack(spacing: LAASpacing.x3) {
                Image(systemName: "folder").foregroundStyle(LAAColor.link)
                Text(verbatim: name).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                Spacer(minLength: 0)
            }.padding(LAASpacing.x4).frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
                .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func folderContents(_ folder: String) -> some View {
        ForEach(LAABrainPaths.folders(in: files, parent: folder), id: \.self) { name in folderLink(name, parent: folder) }
        ForEach(files.filter { $0.folder == folder }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { file in noteLink(file) }
    }

    private func noteLink(_ file: LAABrainFile) -> some View {
        NavigationLink(value: LAABrainRoute.note(LAABrainReference(file: file, includeInbox: includeInbox))) {
            HStack(alignment: .top, spacing: LAASpacing.x4) {
                Image(systemName: "doc.text").foregroundStyle(LAAColor.link)
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: file.title).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                    Text(verbatim: file.path).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    if file.unreadable != nil { Text(verbatim: "本文を読み込めません").laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                }
                Spacer(minLength: 0)
                Text(verbatim: String(file.modifiedAt.prefix(10))).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            .padding(.vertical, LAASpacing.x3).frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .overlay(alignment: .top) { LAAColor.separator.frame(height: 1) }
        }.buttonStyle(.plain).accessibilityIdentifier("laa.brain.note")
    }

    @ViewBuilder private var searchResults: some View {
        if let searchError { failure(searchError) }
        else if isSearching { ProgressView().accessibilityLabel(Text(verbatim: "検索中")) }
        else if hits.isEmpty { Text(verbatim: "検索結果はありません。 ").foregroundStyle(LAAColor.secondaryText) }
        else {
            Text(verbatim: "検索結果（最大10件）").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            ForEach(hits) { hit in
                NavigationLink(value: LAABrainRoute.note(LAABrainReference(path: hit.path, includeInbox: includeInbox))) {
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        Text(verbatim: hit.path).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                        if !hit.section.isEmpty { Text(verbatim: hit.section).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
                        Text(verbatim: hit.text).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(4)
                    }.frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("laa.brain.searchResult")
            }
        }
    }

    private func failure(_ error: LAABridgeError) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Label { Text(verbatim: error.japaneseText) } icon: { Image(systemName: "exclamationmark.triangle") }
                .foregroundStyle(LAAColor.attention)
            Button { Task { if query.isEmpty { await load() } else { await search() } } } label: { Text(verbatim: LAACopy.Brain.retry) }
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
