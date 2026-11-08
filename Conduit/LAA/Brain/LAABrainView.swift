#if LAA_BUILD
import SwiftUI
import UniformTypeIdentifiers

private struct BrainLoadKey: Equatable { let revision: Int; let localRevision: Int; let inbox: Bool; let mac: Bool }
private struct BrainSearchKey: Equatable { let revision: Int; let localRevision: Int; let indexRevision: Int; let inbox: Bool; let query: String; let count: Int }

struct LAABrainPending: Codable {
    let request: LAABrainCreateBody
    let bytes: Data
    let keyValue: String
    let deviceID: String
}

struct LAABrainView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @StateObject private var local = LAABrainLocalVault()
    @ObservedObject private var dailyRequest = LAABrainDailyRequest.shared
    let onRequestSettings: () -> Void
    @Environment(\.laaDesktop) private var laaDesktop
    @State private var path: [LAABrainRoute] = []
    @State private var desktopSelection: LAABrainReference?
    @State private var desktopFolder = ""
    @State private var dailyOpening = false
    @State private var dailyNeedsSelection = false
    @State private var autoEditPath: String?
    @State private var editorIsOpen = false
    @State private var files: [LAABrainFile] = []
    @State private var folderPaths: [String] = []
    @State private var localMode = 1
    @State private var showMacSource = true
    @State private var localCreate: LAABrainLocalCreateTarget?
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
    @State private var showRecovery = false
    @State private var chooseFolder = false
    @State private var localError: String?
    @State private var localReadFailed = false
    @State private var index: LAABrainIndex?
    @State private var indexRevision = 0
    @State private var isIndexing = false
    @State private var pins = Set<String>()
    @State private var selectedTag: String?
    @State private var pending: LAABrainPending?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
            if laaDesktop {
                desktopBody
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar { desktopToolbar }
            } else {
            ZStack {
                LAAColor.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: LAASpacing.section) {
                        heading
                        if local.isSelected {
                            localSource
                            if local.state == .needsAccess { localAccessView }
                            else { localBrowser }
                        } else if showMacSource || useBridgeFixture {
                            sourceSelector
                            if LAABrainData.available(bridge) { browser } else { connectionView }
                        } else {
                            localIntroduction
                        }
                    }
                    .padding(.horizontal, LAASpacing.horizontal)
                    .padding(.vertical, LAASpacing.x4)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .refreshable { await load() }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                // Creation stays leading so the settings button sits where every
                // other tab puts it (the common-position check compares frames).
                if local.isReady {
                    ToolbarItem(placement: .topBarLeading) { createMenu(parent: "") }
                }
                if !local.isSelected && (showMacSource || useBridgeFixture) && LAABrainData.available(bridge) {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showCreate = true } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel(Text(verbatim: LAACopy.Brain.newNote))
                            .accessibilityIdentifier("laa.brain.create")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    LAASettingsButton(action: onRequestSettings)
                }
            }
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
                                Label { Text(verbatim: local.isReady ? "戻る" : LAACopy.Brain.back) } icon: { Image(systemName: "chevron.left") }
                            }.accessibilityIdentifier("laa.brain.back")
                        }
                        if local.isReady {
                            ToolbarItem(placement: .topBarTrailing) { createMenu(parent: folder) }
                        }
                    }
                case .note(let reference):
                    LAABrainNoteView(reference: reference, files: files, local: local, isLocal: local.isReady,
                                     index: index, isPinned: pins.contains(reference.path),
                                     togglePin: { togglePin(reference.path) }, path: $path,
                                     autoEditPath: $autoEditPath, editorIsOpen: $editorIsOpen)
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
        .sheet(item: $localCreate) { target in
            if let root = try? local.snapshot() {
                LAABrainLocalCreateView(root: root, target: target) { newPath, kind in
                    switch kind {
                    case .note: path.append(.note(LAABrainReference(path: newPath, includeInbox: true)))
                    case .folder: path.append(.folder(newPath))
                    }
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $showRecovery) {
            if let root = try? local.snapshot() {
                LAABrainRecoveryCatalogueView(root: root) { Task { await load() } }
            } else {
                Text("Folder access is unavailable.")
            }
        }
        .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            do {
                guard let selected = try result.get().first else { return }
                try local.connect(selected)
                resetLocalNavigation(); dailyNeedsSelection = false
                openDailyIfPossible()
            } catch { localError = (error as? LAABrainVaultError)?.message ?? LAABrainVaultError.unreadable.message }
        }
        .task(id: BrainLoadKey(revision: bridge.revision, localRevision: local.revision, inbox: includeInbox, mac: showMacSource || useBridgeFixture)) { await load() }
        .task(id: BrainSearchKey(revision: bridge.revision, localRevision: local.revision, indexRevision: indexRevision, inbox: includeInbox, query: query, count: files.count)) { await search() }
        .onChange(of: dailyRequest.id, initial: true) { _, _ in openDailyIfPossible() }
        .onChange(of: local.state) { _, _ in openDailyIfPossible() }
        .onChange(of: dailyBlocked) { _, _ in openDailyIfPossible() }
    }

    private var dailyBlocked: Bool {
        editorIsOpen || localCreate != nil || showCreate || showRecovery || showPairing || chooseFolder
    }

    // MARK: Desktop (Mac) list and detail

    /// The Mac shell gives this screen the whole detail column. The list keeps
    /// the phone's search, source and folder browsing; choosing a note fills
    /// the reading column instead of pushing the list away.
    private var desktopBody: some View {
        LAAMacListDetail(listWidth: LAADesktopMetrics.listIdealWidth) {
            desktopList
        } detail: {
            desktopDetail
        }
        .background(LAAColor.background.ignoresSafeArea())
        .background {
            LAABrainDesktopShortcuts(search: { searchFocused = true },
                                     reload: { Task { await load() } },
                                     create: createFromKeyboard)
        }
    }

    private var desktopList: some View {
        VStack(alignment: .leading, spacing: 0) {
            LAABrainDesktopHeader(
                subtitle: local.isSelected ? nil : LAACopy.Brain.subtitle,
                canCreate: false,
                canRefresh: true,
                isRefreshing: isLoading,
                create: {},
                refresh: { Task { await load() } }
            )
            .padding(.horizontal, LAASpacing.x4)
            .padding(.top, LAASpacing.x4)
            ScrollView {
                LAAMacKeyboardList(count: desktopNotes.count,
                                  selectedIndex: desktopNotes.firstIndex { $0.path == desktopSelection?.path },
                                  move: { index in
                                      guard desktopNotes.indices.contains(index) else { return }
                                      desktopSelection = LAABrainReference(file: desktopNotes[index], includeInbox: includeInbox)
                                  },
                                  open: {}) {
                    VStack(alignment: .leading, spacing: LAASpacing.x4) {
                        #if targetEnvironment(macCatalyst)
                        macLocalSelector
                        #else
                        sourceSelector
                        #endif
                        #if targetEnvironment(macCatalyst)
                        if local.isSelected {
                            if local.state == .needsAccess { localAccessView } else { localBrowser }
                        } else if useBridgeFixture {
                            if LAABrainData.available(bridge) { browser } else { connectionView }
                        } else if local.location != nil {
                            Text("フォルダを選んでください。")
                        } else {
                            Text("Brain または HQ を選んでください。")
                        }
                        #else
                        if local.isSelected {
                            if local.state == .needsAccess { localAccessView } else { localBrowser }
                        } else if showMacSource || useBridgeFixture {
                            if LAABrainData.available(bridge) { browser } else { connectionView }
                        } else {
                            localIntroduction
                        }
                        #endif
                    }
                    .padding(.horizontal, LAASpacing.x4)
                    .padding(.vertical, LAASpacing.x4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var desktopDetail: some View {
        if let selection = desktopSelection {
            LAABrainNoteView(reference: selection, files: files, local: local, isLocal: local.isReady,
                             index: index, isPinned: pins.contains(selection.path),
                             togglePin: { togglePin(selection.path) }, path: $path,
                             autoEditPath: $autoEditPath, editorIsOpen: $editorIsOpen,
                             showsBackButton: false, usesNavigationTitle: false,
                             contentMaxWidth: LAADesktopMetrics.documentWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LAAMacEmptyDetail(symbol: "doc.text", title: "ノートを選ぶ",
                              message: "左の一覧からノートを選ぶと、ここに本文を表示します。")
        }
    }

    @ToolbarContentBuilder private var desktopToolbar: some ToolbarContent {
        if local.isReady {
            ToolbarItem(placement: .topBarLeading) { createMenu(parent: desktopFolder) }
        }
        if !local.isSelected && (showMacSource || useBridgeFixture) && LAABrainData.available(bridge) {
            ToolbarItem(placement: .topBarLeading) {
                Button { showCreate = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel(Text(verbatim: LAACopy.Brain.newNote))
                    .accessibilityIdentifier("laa.brain.create")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            LAASettingsButton(action: onRequestSettings)
        }
    }

    private var desktopActions: LAABrainDesktopActions? {
        guard laaDesktop else { return nil }
        return LAABrainDesktopActions(
            selectedPath: desktopSelection?.path ?? "",
            folder: desktopFolder,
            select: { desktopSelection = $0 },
            openFolder: { desktopFolder = $0 }
        )
    }

    private func createFromKeyboard() {
        if local.isReady {
            localCreate = LAABrainLocalCreateTarget(parent: desktopFolder, kind: .note)
        } else if LAABrainData.available(bridge) {
            showCreate = true
        }
    }

    /// Rows the keyboard moves through, in the order the list shows them.
    private var desktopNotes: [LAABrainFile] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            return hits.compactMap { hit in files.first { $0.path == hit.path } }
        }
        let browsingLocal = local.isSelected
        let currentMode = browsingLocal ? localMode : mode
        switch currentMode {
        case 0:
            return files.sorted { $0.modifiedAt > $1.modifiedAt }
        case 2:
            guard let selectedTag else { return [] }
            return index?.files(tag: selectedTag) ?? []
        case 3:
            return files.filter { $0.conflictOriginalPath != nil }
        default:
            return files.filter { $0.folder == desktopFolder }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    /// Feed the phone's route into the column that is showing it.
    private func showBrainRoute(_ route: LAABrainRoute?) {
        guard laaDesktop else {
            path = route.map { [$0] } ?? []
            return
        }
        switch route {
        case .note(let reference): desktopSelection = reference
        case .folder(let folder): desktopFolder = folder; mode = 1
        case nil: desktopSelection = nil
        }
        path = []
    }

    @MainActor private func openDailyIfPossible() {
        guard let request = dailyRequest.id, !dailyOpening, !dailyBlocked else { return }
        #if targetEnvironment(macCatalyst)
        if local.location != .brain || !local.isReady {
            if local.location != .brain { resetLocalNavigation() }
            guard local.prepareDaily() else {
                if !dailyNeedsSelection {
                    dailyNeedsSelection = true
                    localError = "今日のノートを開くにはBrainフォルダを選んでください。"
                    chooseFolder = true
                }
                return
            }
        }
        #endif
        guard local.isReady, let root = try? local.snapshot() else { return }
        dailyOpening = true
        Task {
            do {
                let dailyPath = try await Task.detached(priority: .userInitiated) {
                    try LAABrainDailyNote.open(root: root)
                }.value
                dailyOpening = false
                guard dailyRequest.id == request else { openDailyIfPossible(); return }
                guard !dailyBlocked else { return }
                guard (try? local.snapshot()) == root else { openDailyIfPossible(); return }
                autoEditPath = dailyPath
                showBrainRoute(.note(LAABrainReference(path: dailyPath, includeInbox: true)))
                localError = nil
                dailyRequest.consume(request)
            } catch {
                dailyOpening = false
                guard dailyRequest.id == request else { openDailyIfPossible(); return }
                guard !dailyBlocked else { return }
                guard (try? local.snapshot()) == root else { openDailyIfPossible(); return }
                localError = AppLocalization.string("今日のノートを開けません。フォルダとノートを確認してください。")
                showBrainRoute(nil)
                dailyRequest.consume(request)
            }
        }
    }

    private var useBridgeFixture: Bool {
        #if DEBUG
        LAABrainData.isTestFixture
        #else
        false
        #endif
    }

    private func resetLocalNavigation() {
        path = []; desktopSelection = nil; desktopFolder = ""; files = []; folderPaths = []
        index = nil; indexRevision += 1; hits = []; query = ""; selectedTag = nil
        pins = []; localMode = 1; autoEditPath = nil; localError = nil
        isLoading = false; isIndexing = false; isSearching = false; localReadFailed = false
    }

    #if targetEnvironment(macCatalyst)
    private var macLocalSelector: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack {
                ForEach(LAABrainLocalVault.Location.allCases, id: \.rawValue) { target in
                    Button(target.rawValue) {
                        resetLocalNavigation()
                        local.select(target)
                        if !local.isReady { chooseFolder = true }
                    }
                    .disabled(dailyBlocked || dailyOpening)
                    .accessibilityIdentifier("laa.brain.location.\(target.rawValue)")
                }
                Spacer()
                if let location = local.location { Text(verbatim: location.rawValue).laaTextStyle(.secondary) }
            }
            if local.location != nil {
                Button("フォルダを選び直す") { chooseFolder = true }
                    .disabled(dailyBlocked || dailyOpening)
                    .accessibilityIdentifier("laa.brain.chooseFolder")
            }
            if local.isReady {
                Button("復元履歴") { showRecovery = true }
                    .accessibilityIdentifier("laa.brain.recovery.open")
            }
            if let localError { Text(verbatim: localError).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
        }
    }
    #endif

    private var localIntroduction: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Text("SyncTrainで同期しているBrainフォルダを選んでください。")
            Button("フォルダを選ぶ") { chooseFolder = true }
                .laaGlassButton(prominent: true).accessibilityIdentifier("laa.brain.chooseFolder")
            Button("Mac接続で開く") { showMacSource = true }.laaTextStyle(.secondary)
                .accessibilityIdentifier("laa.brain.openMac")
            if let localError { Text(verbatim: localError).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
        }.foregroundStyle(LAAColor.text)
    }

    private var localSource: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack {
                Label("このiPhoneのフォルダ", systemImage: "folder")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .accessibilityIdentifier("laa.brain.localSource")
                Spacer()
                Menu {
                    Button("別のフォルダを選ぶ") { chooseFolder = true }
                    Button("復元履歴") { showRecovery = true }.accessibilityIdentifier("laa.brain.recovery.open")
                    Button("Mac接続で開く") {
                        do { try local.disconnect(); showMacSource = true; path = []; query = "" }
                        catch { localError = LAABrainVaultError.unreadable.message }
                    }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("フォルダの設定") }
                .accessibilityIdentifier("laa.brain.localOptions")
            }
            if let localError { Text(verbatim: localError).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
        }
    }

    private func createMenu(parent: String) -> some View {
        Menu {
            Button("今日のデイリーノートを開く") { dailyRequest.enqueue() }
                .accessibilityIdentifier("laa.brain.daily")
            Button("新規ノート", systemImage: "square.and.pencil") { localCreate = LAABrainLocalCreateTarget(parent: parent, kind: .note) }
                .accessibilityIdentifier("laa.brain.localCreate.note")
            Button("新規フォルダ", systemImage: "folder.badge.plus") { localCreate = LAABrainLocalCreateTarget(parent: parent, kind: .folder) }
                .accessibilityIdentifier("laa.brain.localCreate.folder")
        } label: { Image(systemName: "plus").accessibilityLabel("新規作成") }
        .accessibilityIdentifier("laa.brain.localCreate")
    }

    private var localBrowser: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(LAAColor.secondaryText)
                TextField("ノートを検索", text: $query)
                    .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                    .accessibilityIdentifier("laa.brain.search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("検索を消す")
                }
            }
            .padding(.horizontal, LAASpacing.x4).frame(minHeight: LAASpacing.minimumTouchTarget)
            .laaGlass(in: Capsule())
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults
            } else if localReadFailed {
                Button("再読み込み") { Task { await load() } }
            } else if isLoading && files.isEmpty && folderPaths.isEmpty {
                ProgressView()
            } else {
                HStack {
                    Text(localMode == 0 ? AppLocalization.string("最近のノート") : localMode == 2 ? AppLocalization.string("タグ") : localMode == 3 ? AppLocalization.string("競合") : localMode == 4 ? AppLocalization.string("Gallery") : AppLocalization.string("フォルダとノート"))
                        .laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                    Spacer()
                    Menu {
                        Button("フォルダとノート") { localMode = 1 }
                        Button("最近のノート") { localMode = 0 }.accessibilityIdentifier("laa.brain.filter.recent")
                        Button("タグ") { localMode = 2; selectedTag = nil }.accessibilityIdentifier("laa.brain.filter.tags")
                        Button { localMode = 4 } label: { Text(verbatim: "ギャラリー") }
                            .accessibilityIdentifier("laa.brain.filter.gallery")
                        if files.contains(where: { $0.conflictOriginalPath != nil }) { Button("競合") { localMode = 3 } }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle").accessibilityLabel("表示を切り替える") }
                        .accessibilityIdentifier("laa.brain.localDisplay")
                }
                if localMode == 0 { recent }
                else if localMode == 2 { tagBrowser }
                else if localMode == 3 { conflictBrowser }
                else if localMode == 4 { galleryBrowser }
                else if laaDesktop {
                    LAABrainDesktopBreadcrumb(folder: desktopFolder) { desktopFolder = $0 }
                    folderContents(desktopFolder)
                }
                else { folderContents("") }
            }
        }.foregroundStyle(LAAColor.text)
    }

    private var sourceSelector: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack {
                Label { Text(verbatim: local.isSelected ? LAACopy.Brain.localFolder : LAACopy.Brain.macConnection) }
                    icon: { Image(systemName: local.isSelected ? "folder" : "desktopcomputer") }
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                Spacer()
                Button(local.isSelected ? LAACopy.Brain.changeFolder : LAACopy.Brain.chooseFolder) { chooseFolder = true }
                    .laaTextStyle(.secondary).accessibilityIdentifier("laa.brain.chooseFolder")
            }
            if local.isSelected {
                Button(LAACopy.Brain.useMac) {
                    do { try local.disconnect(); localError = nil; path = []; query = ""; selectedTag = nil }
                    catch { localError = LAABrainVaultError.unreadable.message }
                }.laaTextStyle(.secondary).accessibilityIdentifier("laa.brain.useMac")
            }
            if local.isReady {
                Button("Recovery history") { showRecovery = true }
                    .laaTextStyle(.secondary).accessibilityIdentifier("laa.brain.recovery.open")
            }
            if let localError { Text(verbatim: localError).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
        }
    }

    private var localAccessView: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            #if targetEnvironment(macCatalyst)
            if local.location == nil {
                Text("Brain または HQ を選んでください。")
            } else {
                Text(verbatim: LAABrainVaultError.access.message).foregroundStyle(LAAColor.attention)
                Button("フォルダを選ぶ") { chooseFolder = true }.laaGlassButton(prominent: true)
            }
            #else
            Text(verbatim: LAABrainVaultError.access.message).foregroundStyle(LAAColor.attention)
            Button("フォルダを選ぶ") { chooseFolder = true }.laaGlassButton(prominent: true)
            #endif
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            LAATabHeading(title: LAACopy.Brain.title, identifier: "laa.brain.title")
            if !local.isSelected && (showMacSource || useBridgeFixture) {
                Text(verbatim: LAACopy.Brain.subtitle).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
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
            .laaGlass(in: Capsule())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LAASpacing.x2) {
                    chip(LAACopy.Brain.recent, selected: mode == 0) { mode = 0 }
                    chip(LAACopy.Brain.folders, selected: mode == 1) { mode = 1 }
                    chip(LAACopy.Brain.tags, selected: mode == 2) { mode = 2; selectedTag = nil }
                        .disabled(!local.isReady).accessibilityHint(Text(verbatim: local.isReady ? "" : LAACopy.Brain.tagsUnavailable))
                    if files.contains(where: { $0.conflictOriginalPath != nil }) {
                        chip("Conflicts", selected: mode == 3) { mode = 3 }
                    }
                }
            }
            .scrollClipDisabled()
            if !local.isReady {
                Text(verbatim: LAACopy.Brain.tagsUnavailable).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults
            } else if local.isSelected, localReadFailed {
                Button(LAACopy.Brain.retry) { Task { await load() } }
            } else if let listError {
                failure(listError)
            } else if isLoading && files.isEmpty {
                ProgressView().accessibilityLabel(Text(verbatim: LAACopy.loading))
            } else if files.isEmpty {
                Text(verbatim: "表示できるメモはありません。").foregroundStyle(LAAColor.secondaryText)
            } else if mode == 0 {
                recent
            } else if mode == 2 {
                tagBrowser
            } else if mode == 3 {
                conflictBrowser
            } else {
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    if laaDesktop {
                        LAABrainDesktopBreadcrumb(folder: desktopFolder) { desktopFolder = $0 }
                    } else {
                        sectionHeading(LAACopy.Brain.folders)
                    }
                    folderContents(laaDesktop ? desktopFolder : "")
                }
            }
        }
        .foregroundStyle(LAAColor.text)
    }

    private var conflictBrowser: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            sectionHeading("Conflicts")
            Text(verbatim: "Both copies are kept. Review them before making changes.")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            ForEach(files.filter { $0.conflictOriginalPath != nil }) { conflict in
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: "Conflict copy").laaTextStyle(.section).foregroundStyle(LAAColor.attention)
                    noteLink(conflict)
                    if let original = files.first(where: { $0.path == conflict.conflictOriginalPath }) {
                        Text(verbatim: "Original").laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                        noteLink(original)
                    } else {
                        Text(verbatim: "Original is unavailable.").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // The same glass pills as Work's sections.
            Text(verbatim: title).laaTextStyle(.secondary).fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? LAAColor.link : LAAColor.secondaryText)
                .padding(.horizontal, LAASpacing.x4)
                .frame(minHeight: LAASpacing.minimumTouchTarget)
        }.buttonStyle(.plain)
            .laaGlass(in: Capsule(), selected: selected)
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
                    .laaGlassButton(prominent: true).accessibilityIdentifier("laa.bridge.openPairing")
            }
        }.laaTextStyle(.body).foregroundStyle(LAAColor.text)
    }

    private var recent: some View {
        let sorted = files.sorted { $0.modifiedAt > $1.modifiedAt }
        let pinned = sorted.filter { pins.contains($0.path) }
        let roots = LAABrainPaths.folders(in: files, parent: "")
        return VStack(alignment: .leading, spacing: LAASpacing.x3) {
            if !pinned.isEmpty {
                sectionHeading(LAACopy.Brain.pinned)
                ForEach(pinned) { file in noteLink(file) }
            }
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
                    Button(LAACopy.Brain.browse) { if local.isReady { localMode = 1 } else { mode = 1 } }.laaTextStyle(.secondary)
                }.padding(.top, LAASpacing.section)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: LAASpacing.x2), GridItem(.flexible())], spacing: LAASpacing.x2) {
                    ForEach(Array(roots.prefix(2)), id: \.self) { name in folderLink(name, parent: "") }
                }
            }
        }
    }

    @ViewBuilder private var galleryBrowser: some View {
        if isIndexing { ProgressView(LAACopy.Brain.indexing) }
        else if let index {
            LAABrainGalleryView(index: index, files: files, local: local) { path.append(.note($0)) }
        }
    }

    @ViewBuilder private var tagBrowser: some View {
        if isIndexing { ProgressView(LAACopy.Brain.indexing) }
        else if let selectedTag {
            Button(LAACopy.Brain.back) { self.selectedTag = nil }
            sectionHeading("#" + selectedTag)
            ForEach(index?.files(tag: selectedTag) ?? []) { noteLink($0) }
        } else if let index, !index.tags.isEmpty {
            sectionHeading(LAACopy.Brain.tags)
            ForEach(index.tags, id: \.self) { tag in
                Button { selectedTag = tag } label: { Text(verbatim: "#" + tag) }
                    .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
            }
        } else {
            Text(verbatim: "No tags found.").foregroundStyle(LAAColor.secondaryText)
        }
        if let index, index.unreadableCount > 0 {
            Text(verbatim: "\(index.unreadableCount) notes could not be indexed.")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
        }
    }

    @ViewBuilder private func folderLink(_ name: String, parent: String) -> some View {
        let child = parent.isEmpty ? name : parent + "/" + name
        if let desktop = desktopActions {
            LAABrainDesktopFolderRow(name: name) { desktop.openFolder(child) }
        } else {
            NavigationLink(value: LAABrainRoute.folder(child)) {
                HStack(spacing: LAASpacing.x3) {
                    Image(systemName: "folder").foregroundStyle(LAAColor.link)
                    Text(verbatim: name).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                    Spacer(minLength: 0)
                }.padding(LAASpacing.x4).frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
                    .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            }.buttonStyle(.plain)
        }
    }

    private func folderNames(_ folder: String) -> [String] {
        guard local.isReady else { return LAABrainPaths.folders(in: files, parent: folder) }
        let prefix = folder.isEmpty ? "" : folder + "/"
        return folderPaths.compactMap { candidate -> String? in
            guard candidate.hasPrefix(prefix) else { return nil }
            let remainder = String(candidate.dropFirst(prefix.count))
            return remainder.isEmpty || remainder.contains("/") ? nil : remainder
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    @ViewBuilder private func folderContents(_ folder: String) -> some View {
        let children = folderNames(folder)
        let notes = files.filter { $0.folder == folder }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if local.isReady && children.isEmpty && notes.isEmpty && !isLoading {
            Text("このフォルダは空です。右上の＋から作成できます。")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                .accessibilityIdentifier("laa.brain.emptyFolder")
        }
        ForEach(children, id: \.self) { name in folderLink(name, parent: folder) }
        ForEach(notes) { file in noteLink(file) }
    }

    @ViewBuilder private func noteLink(_ file: LAABrainFile) -> some View {
        let reference = LAABrainReference(file: file, includeInbox: includeInbox)
        if let desktop = desktopActions {
            LAABrainDesktopNoteRow(file: file, isSelected: desktop.selectedPath == file.path,
                                   showsPath: !local.isReady, isPinned: pins.contains(file.path),
                                   open: { desktop.select(reference) },
                                   togglePin: { togglePin(file.path) })
        } else {
            NavigationLink(value: LAABrainRoute.note(reference)) {
                HStack(alignment: .top, spacing: LAASpacing.x4) {
                    Image(systemName: "doc.text").foregroundStyle(LAAColor.link)
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        Text(verbatim: file.title).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                        if !local.isReady { Text(verbatim: file.path).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
                        if file.conflictOriginalPath != nil { Text(verbatim: local.isReady ? "競合コピー" : "Sync conflict").laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                        if file.unreadable != nil { Text(verbatim: "本文を読み込めません").laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                    }
                    Spacer(minLength: 0)
                    if !local.isReady { Text(verbatim: String(file.modifiedAt.prefix(10))).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
                }
                .padding(.vertical, LAASpacing.x3).frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
                .overlay(alignment: .top) { LAAColor.separator.frame(height: 1) }
            }.buttonStyle(.plain).accessibilityIdentifier("laa.brain.note")
        }
    }

    @ViewBuilder private var searchResults: some View {
        if let searchError { failure(searchError) }
        else if isSearching || (local.isReady && isIndexing) { ProgressView().accessibilityLabel(Text(verbatim: "検索中")) }
        else if hits.isEmpty { Text(verbatim: "検索結果はありません。 ").foregroundStyle(LAAColor.secondaryText) }
        else {
            Text(verbatim: local.isReady ? "Search results" : "検索結果（最大10件）").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            ForEach(hits) { hit in
                if let desktop = desktopActions {
                    Button { desktop.select(LAABrainReference(path: hit.path, includeInbox: includeInbox)) } label: {
                        VStack(alignment: .leading, spacing: LAASpacing.x1) {
                            Text(verbatim: hit.path).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                            if !hit.section.isEmpty { Text(verbatim: hit.section).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
                            Text(verbatim: hit.text).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(4)
                        }
                        .padding(.horizontal, LAASpacing.x3)
                        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
                        .background(desktop.selectedPath == hit.path ? LAAColor.selectionFill : Color.clear,
                                    in: RoundedRectangle(cornerRadius: LAASpacing.x2))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("laa.brain.searchResult")
                        .help(hit.path)
                } else {
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
        if local.isReady, let index, index.unreadableCount > 0 {
            Text(verbatim: "\(index.unreadableCount) notes could not be indexed.")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
        }
    }

    @MainActor private func togglePin(_ path: String) {
        do {
            var updated = pins
            if updated.contains(path) { updated.remove(path) } else { updated.insert(path) }
            try LAABrainPins.save(updated, root: local.isReady ? local.snapshot() : nil)
            pins = updated
        } catch { localError = "ピンを保存できませんでした。" }
    }

    private func failure(_ error: LAABridgeError) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Label { Text(verbatim: error == .forbidden ? LAACopy.Brain.ownerPermissionRequired : error.japaneseText) } icon: { Image(systemName: "exclamationmark.triangle") }
                .foregroundStyle(LAAColor.attention)
                .accessibilityIdentifier(error == .forbidden ? "laa.brain.ownerPermission" : "laa.brain.readError")
            Button { Task { if query.isEmpty { await load() } else { await search() } } } label: { Text(verbatim: LAACopy.Brain.retry) }
        }
    }

    @MainActor private func load() async {
        if local.isSelected {
            let selectedRoot = try? local.snapshot()
            listError = nil; localReadFailed = false; isLoading = true; isIndexing = false
            do {
                let root = try local.snapshot()
                let listing = try await Task.detached(priority: .userInitiated) { try LAABrainVaultIO.listing(root: root) }.value
                try Task.checkCancellation()
                guard (try? local.snapshot()) == root else { return }
                let result = listing.files
                files = result; folderPaths = listing.folders; isLoading = false; localError = nil; isIndexing = true
                do { pins = try LAABrainPins.load(root: root) }
                catch { localError = "ピンを読み込めませんでした。" }
                let job = Task.detached(priority: .utility) {
                    LAABrainIndex(files: result) { path in try LAABrainVaultIO.note(root: root, path: path).text }
                }
                let built = await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
                try Task.checkCancellation()
                guard (try? local.snapshot()) == root else { return }
                index = built; indexRevision += 1; isIndexing = false
            } catch is CancellationError { return }
            catch {
                guard selectedRoot == (try? local.snapshot()) else { return }
                localError = (error as? LAABrainVaultError)?.message ?? LAABrainVaultError.unreadable.message
                localReadFailed = true; isLoading = false; isIndexing = false
            }
            return
        }
        index = nil; isIndexing = false
        do { pins = try LAABrainPins.load(root: nil) }
        catch { localError = "ピンを読み込めませんでした。" }
        guard (showMacSource || useBridgeFixture), LAABrainData.available(bridge) else { files = []; listError = nil; isLoading = false; return }
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
        if local.isSelected {
            hits = []; searchError = nil
            guard !term.isEmpty, local.isReady else { isSearching = false; return }
            guard let index, !isIndexing, let root = try? local.snapshot() else { isSearching = false; return }
            let searchIndexRevision = indexRevision
            isSearching = true
            do {
                try await Task.sleep(for: .milliseconds(350))
                let results = await Task.detached(priority: .userInitiated) { index.search(term) }.value
                try Task.checkCancellation()
                guard (try? local.snapshot()) == root, searchIndexRevision == indexRevision,
                      term == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                hits = results; isSearching = false
            } catch is CancellationError { return }
            catch { localError = LAABrainVaultError.unreadable.message; isSearching = false }
            return
        }
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
