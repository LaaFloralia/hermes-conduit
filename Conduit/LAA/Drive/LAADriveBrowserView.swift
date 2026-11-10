#if LAA_BUILD
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Assets screen supplies the authenticated loaders and opens files. The
/// browser owns only its section, folder path, search and presentation state.
@MainActor
struct LAADriveBrowserView: View {
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var bridge: LAABridgeSession
    typealias Loader = LAADriveBrowseController.Loader
    typealias ThumbnailLoader = @MainActor (LAADriveListingItem) async throws -> Data?
    typealias ShortcutLoader = @MainActor (LAADriveListingItem, Set<String>) async throws -> LAADriveListingItem

    let revision: Int
    let refreshID: Int
    let cached: (LAADriveBrowseQuery) -> LAADriveListingPage?
    let upload: (String?) -> Void
    let load: Loader
    let loadThumbnail: ThumbnailLoader
    let resolveShortcut: ShortcutLoader
    let errorMessage: (Error) -> String
    let open: (LAADriveListingItem, [LAADriveItem]) -> Void
    let saveFile: (LAADriveListingItem) -> Void
    let saveFolder: (LAADriveListingItem) -> Void
    /// The Mac list shows files as rows with columns and keeps the selection
    /// visible while the detail column shows the file.
    var desktop = false
    var selectedID: String?
    let layoutToggle: Int

    init(revision: Int, refreshID: Int = 0, cached: @escaping (LAADriveBrowseQuery) -> LAADriveListingPage? = { _ in nil }, upload: @escaping (String?) -> Void = { _ in }, load: @escaping Loader, loadThumbnail: @escaping ThumbnailLoader,
         resolveShortcut: @escaping ShortcutLoader,
         errorMessage: @escaping (Error) -> String, open: @escaping (LAADriveListingItem, [LAADriveItem]) -> Void,
         saveFolder: @escaping (LAADriveListingItem) -> Void = { _ in },
         saveFile: @escaping (LAADriveListingItem) -> Void = { _ in },
         desktop: Bool = false, selectedID: String? = nil, layoutToggle: Int = 0) {
        self.desktop = desktop
        self.selectedID = selectedID
        self.layoutToggle = layoutToggle
        self.cached = cached; self.upload = upload
        self.revision = revision; self.refreshID = refreshID
        self.load = load
        self.loadThumbnail = loadThumbnail
        self.resolveShortcut = resolveShortcut
        self.errorMessage = errorMessage
        self.open = open
        self.saveFolder = saveFolder; self.saveFile = saveFile
    }

    @StateObject private var controller = LAADriveBrowseController()
    @State private var section: LAADriveBrowseSection = .my
    @State private var folders: [LAADriveListingItem] = []
    @State private var search = ""
    @State private var layout: Layout = .grid
    @State private var waiting = true
    @State private var displayedKey: LoadKey?
    @State private var navigationError: String?
    @State private var resolvingID: String?
    @State private var resolutionGeneration: UInt64 = 0
    @State private var resolutionTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var dropTargeted = false
    @State private var droppedFile: DroppedFile?

    @State private var fileType: LAADriveFileFilter = .all
    @State private var availableKinds: Set<LAADriveFileFilter> = []
    @State private var sort: LAADriveBrowseOrder = .name
    private enum Layout: String { case grid, list }
    private var preferenceKey: String { "drive.presentation." + (bridge.deviceID ?? "none") + "." + section.rawValue + "." + (folders.last?.id ?? "root") }
    private var visibleItems: [LAADriveListingItem] {
        controller.items.sorted {
            if sort == .recent, $0.item.modifiedAt != $1.item.modifiedAt { return ($0.item.modifiedAt ?? "") > ($1.item.modifiedAt ?? "") }
            return $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending
        }
    }
    /// A dropped file copied where the upload sheet can read it.
    private struct DroppedFile: Identifiable {
        let id = UUID()
        let url: URL
    }
    private struct LoadKey: Equatable {
        let revision: Int
        let refreshID: Int
        let section: LAADriveBrowseSection
        let folderID: String?
        let search: String
        let fileType: LAADriveFileFilter
        let order: LAADriveBrowseOrder
    }
    private var key: LoadKey {
        .init(revision: revision, refreshID: refreshID, section: section, folderID: folders.last?.id, search: search, fileType: fileType, order: sort)
    }

    private var columns: [GridItem] {
        if desktop {
            return [GridItem(.adaptive(minimum: 180), spacing: LAASpacing.x6)]
        }
        return dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] :
            Array(repeating: GridItem(.flexible(), spacing: LAASpacing.x3), count: 2)
    }

    var body: some View {
        browser
            .modifier(LAADriveSearchPlacement(desktop: desktop, query: $search))
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            desktopBreadcrumb
            if desktop { searchField }
            if availableKinds.count > 1 { filters }
            header
            results
        }
        .tint(LAAColor.link)
        .refreshable { await reload(key, debounce: false) }
        .task(id: preferenceKey) {
            layout = Layout(rawValue: UserDefaults.standard.string(forKey: preferenceKey + ".layout") ?? "") ?? (desktop ? .list : .grid)
            sort = LAADriveBrowseOrder(rawValue: UserDefaults.standard.string(forKey: preferenceKey + ".sort") ?? "") ?? .name
        }
        .onChange(of: layoutToggle) { _, _ in layout = layout == .grid ? .list : .grid }
        .onChange(of: layout) { _, value in UserDefaults.standard.set(value.rawValue, forKey: preferenceKey + ".layout") }
        .onChange(of: sort) { _, value in UserDefaults.standard.set(value.rawValue, forKey: preferenceKey + ".sort") }
        // Files dropped on the list take the upload sheet's existing path. Mac
        // and iPad both accept the drop; nothing changes for a phone's taps.
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in acceptDrop(providers) }
        .overlay { dropTarget }
        .sheet(item: $droppedFile) { dropped in
            LAADriveUpload(folderId: folders.last?.id, droppedFile: dropped.url, ownsDroppedFile: true) {
                Task { await reload(key, debounce: false) }
            }
            .environmentObject(bridge)
            .laaSheetSize(.form)
        }
        .task(id: key) { [requested = key] in await reload(requested, debounce: true) }
        .onChange(of: revision) { _, _ in
            controller.invalidate()
            folders = []
            search = ""
            section = .my
            fileType = .all
            availableKinds = []
        }
        .onChange(of: key) { previous, current in
            cancelResolution()
            if previous.folderID != current.folderID || previous.section != current.section {
                fileType = .all
                availableKinds = []
            }
        }
        .onChange(of: controller.items) { _, items in
            guard fileType == .all, search.isEmpty else { return }
            availableKinds = Set(items.lazy.filter { !$0.item.isFolder }.map {
                if $0.item.mimeType.hasPrefix("video/") { return .video }
                if $0.item.isImage { return .image }
                return .document
            })
        }
        .onDisappear { cancelResolution() }
        // ⌘F and ⌘R act on this column: the search field above the list and
        // the header's reload, the same two controls the Mac shows. Upload
        // keeps its own button, so the File menu's new item is off by name.
        .laaMacSectionCommands(LAAMacSectionCommands(
            newTitle: AppLocalization.string("Upload Files"),
            canCreate: false,
            canSearch: true,
            focusSearch: { searchFocused = true },
            canReload: !waiting && !controller.loading,
            reload: { Task { await reload(key, debounce: false) } }
        ))
    }

    /// Section ▸ folder ▸ subfolder, each step clickable, replaces the phone's
    /// single "Back to" button in the desktop column.
    private var desktopBreadcrumb: some View {
        HStack(spacing: LAASpacing.x1) {
            Button { folders = []; search = "" } label: {
                Text(verbatim: section.title).laaTextStyle(.secondary)
                    .foregroundStyle(folders.isEmpty ? LAAColor.text : LAAColor.link)
            }
            .buttonStyle(.plain).frame(minHeight: LAASpacing.minimumTouchTarget)
            ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(LAAColor.secondaryText)
                    .accessibilityHidden(true)
                Button { folders = Array(folders.prefix(index + 1)); search = "" } label: {
                    Text(verbatim: folder.item.name).laaTextStyle(.secondary).lineLimit(1)
                        .foregroundStyle(index == folders.count - 1 ? LAAColor.text : LAAColor.link)
                }
                .buttonStyle(.plain).frame(minHeight: LAASpacing.minimumTouchTarget)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: LAASpacing.minimumTouchTarget)
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LAASpacing.x2) { filterButtons }
            VStack(alignment: .leading, spacing: LAASpacing.x2) { filterButtons }
        }
    }

    @ViewBuilder private var filterButtons: some View {
        ForEach(LAADriveFileFilter.allCases.filter { $0 == .all || availableKinds.contains($0) }, id: \.self) { option in
            Button { fileType = option; searchFocused = false } label: {
                Text(verbatim: option.title).laaTextStyle(.secondary)
                    .foregroundStyle(option == fileType ? LAAColor.link : LAAColor.secondaryText)
                    .padding(.horizontal, LAASpacing.x3).frame(minHeight: LAASpacing.minimumTouchTarget)
                    .background(option == fileType ? LAAColor.selectionFill : LAAColor.surface,
                                in: Capsule())
            }.buttonStyle(.plain)
                .accessibilityAddTraits(option == fileType ? .isSelected : [])
                .accessibilityIdentifier("laa.drive.filter.\(option.rawValue)")
        }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            HStack(spacing: LAASpacing.x3) {
                Image(systemName: "magnifyingglass").foregroundStyle(LAAColor.secondaryText)
                    .accessibilityHidden(true)
                TextField(String("検索"), text: $search)
                    .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                    .accessibilityIdentifier("laa.drive.browser.search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("検索を消す")
                        .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
                }
            }
            .laaTextStyle(.body).padding(.horizontal, LAASpacing.x4)
            .frame(minHeight: LAASpacing.minimumTouchTarget)
            .background(LAAColor.subtleSurface, in: RoundedRectangle(cornerRadius: LAARadius.card))

        }
    }

    private var header: some View {
        HStack {
            Text(verbatim: "ファイル").font(.footnote.weight(.semibold)).foregroundStyle(LAAColor.secondaryText)
            Spacer()
            Menu {
                Picker(String("場所"), selection: Binding(get: { section }, set: { section = $0; folders = []; search = "" })) {
                    ForEach(LAADriveBrowseSection.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                Picker(String("並び順"), selection: $sort) {
                    ForEach(LAADriveBrowseOrder.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                Button(String("アップロード"), systemImage: "plus") { upload(folders.last?.id) }
                if let folder = folders.last {
                    Button(String("この端末に保存"), systemImage: "arrow.down.circle") { saveFolder(folder) }
                }
                NavigationLink(String("この端末に保存済み")) { LAADriveOfflineScreen() }
            } label: {
                Image(systemName: "ellipsis").frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
            }.accessibilityLabel(String("ファイルの表示と操作")).accessibilityIdentifier("laa.drive.browser.menu")
        }
    }

    @ViewBuilder private var results: some View {
        if (waiting || displayedKey != key || controller.loading) && controller.items.isEmpty {
            LAALoadingDots()
        } else {
            if let navigationError { Text(verbatim: navigationError).foregroundStyle(LAAColor.attention) }
            if let error = controller.error {
                HStack {
                    Text(verbatim: errorMessage(error)).lineLimit(2)
                    Button(String("再試行")) { Task { await reload(key, debounce: false) } }
                }.laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            }
            if controller.items.isEmpty && controller.error == nil {
                Text(verbatim: "ファイルがありません").laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
            if controller.incompleteSearch == true {
                Text(verbatim: "一部の結果を取得できませんでした").laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            }
            rows(visibleItems.filter { $0.item.isFolder })
            if layout == .grid {
                LazyVGrid(columns: columns, spacing: LAASpacing.x4) {
                    ForEach(visibleItems.filter { !$0.item.isFolder && ($0.item.isImage || $0.item.isMedia) }) { cell($0, grid: true) }
                }
                rows(visibleItems.filter { !$0.item.isFolder && !$0.item.isImage && !$0.item.isMedia })
            } else {
                rows(visibleItems.filter { !$0.item.isFolder })
            }
            if controller.cursor != nil && controller.error == nil {
                Button(String("さらに読み込む")) { Task { await controller.loadMore(using: load) } }
                    .disabled(controller.loading).frame(minHeight: LAASpacing.minimumTouchTarget).accessibilityIdentifier("laa.drive.browser.more")
            }
        }
    }

    @ViewBuilder private func rows(_ items: [LAADriveListingItem]) -> some View {
        if !items.isEmpty {
            LazyVStack(spacing: 0) {
                ForEach(items) { entry in
                    cell(entry, grid: false)
                }
            }
        }
    }

    @ViewBuilder private func cell(_ entry: LAADriveListingItem, grid: Bool) -> some View {
        Button { select(entry) } label: {
            if grid {
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    thumbnail(entry).aspectRatio(4.0 / 3, contentMode: .fit)
                        .overlay(alignment: .bottomTrailing) {
                            if let duration = entry.durationSeconds, entry.item.mimeType.hasPrefix("video/") {
                                Text(verbatim: String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60))
                                    .font(.caption.monospacedDigit()).foregroundStyle(LAAColor.text)
                                    .padding(4).background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.selectionChip)).padding(4)
                            }
                        }
                    Text(verbatim: entry.item.name).font(.system(size: 14, weight: .medium)).foregroundStyle(LAAColor.text)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: LAASpacing.x3) {
                    Image(systemName: entry.item.symbol).font(.system(size: 24)).foregroundStyle(LAAColor.link).frame(width: 24)
                    Text(verbatim: entry.item.name).font(.body).foregroundStyle(LAAColor.text).lineLimit(2)
                    Spacer(minLength: 8)
                    if !entry.item.isFolder, let text = entry.item.modifiedAt, let date = Self.date(text) {
                        Text(date, style: .relative).font(.footnote).foregroundStyle(LAAColor.secondaryText).lineLimit(1)
                    }
                }.padding(.horizontal, LAASpacing.x4).frame(minHeight: LAASpacing.minimumRowHeight)
                    .background(selectedID == entry.id ? LAAColor.selectionFill : .clear, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .buttonStyle(LAAListRowStyle()).disabled(resolvingID != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: entry.item.name)).accessibilityValue(Text(verbatim: kind(entry)))
        .accessibilityIdentifier("laa.drive.browser.item.\(entry.id)")
        .contextMenu {
            if let url = entry.safeWebViewURL {
                ShareLink(item: url) { Label(String("共有"), systemImage: "square.and.arrow.up") }
                Button(String("リンクをコピー"), systemImage: "link") { UIPasteboard.general.url = url }
                Link(destination: url) { Label(String("Driveで開く"), systemImage: "arrow.up.right.square") }
            }
            if entry.item.isFolder {
                Button(String("この端末に保存"), systemImage: "arrow.down.circle") { saveFolder(entry) }
            } else {
                Button(String("この端末に保存"), systemImage: "arrow.down.circle") { saveFile(entry) }
                    .disabled(LAADrivePresentation.reason(entry.item) != nil)
            }
        }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private func kind(_ entry: LAADriveListingItem) -> String {
        entry.item.kind == "shortcut" ? AppLocalization.string("Shortcut") : entry.item.kindTitle
    }

    private func select(_ entry: LAADriveListingItem) {
        guard resolvingID == nil else { return }
        navigationError = nil
        guard entry.item.kind == "shortcut" else { navigateOrOpen(entry); return }
        let requested = key
        let visited = Set(folders.map(\.id))
        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        resolvingID = entry.id
        resolutionTask = Task {
            do {
                let target = try await resolveShortcut(entry, visited)
                try Task.checkCancellation()
                guard key == requested, generation == resolutionGeneration else { return }
                resolvingID = nil
                resolutionTask = nil
                navigateOrOpen(target)
            } catch {
                guard key == requested, generation == resolutionGeneration, !Task.isCancelled else { return }
                resolvingID = nil
                resolutionTask = nil
                navigationError = (error as? LAADriveShortcutError)?.message ?? errorMessage(error)
            }
        }
    }

    private func navigateOrOpen(_ entry: LAADriveListingItem) {
        if entry.item.isFolder {
            guard !folders.contains(where: { $0.id == entry.id }) else {
                navigationError = AppLocalization.string("This folder is already in the current path.")
                return
            }
            folders.append(entry)
            search = ""
            searchFocused = false
        } else {
            var images = visibleItems.map(\.item).filter { entry.item.isMedia ? $0.isMedia : $0.isImage }
            if entry.item.isImage && !images.contains(where: { $0.id == entry.id }) { images.append(entry.item) }
            open(entry, images)
        }
    }

    private func cancelResolution() {
        resolutionGeneration &+= 1
        resolutionTask?.cancel()
        resolutionTask = nil
        resolvingID = nil
    }

    private func thumbnail(_ entry: LAADriveListingItem) -> some View {
        LAADriveBrowserThumbnail(entry: entry, revision: revision, load: loadThumbnail)
            .accessibilityHidden(true)
    }

    /// A quiet frame while a file is held over the list: enough to show where
    /// it lands, without covering the files.
    @ViewBuilder private var dropTarget: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: LAARadius.card)
                .strokeBorder(LAAColor.link, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(LAAColor.link.opacity(0.06), in: RoundedRectangle(cornerRadius: LAARadius.card))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Only the first file is taken: the upload sheet sends one file at a time.
    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? item as? URL
                guard let url else { return }
                Task { @MainActor in receive(url) }
            }
            return true
        }
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return false }
        // The representation's URL is removed when this handler returns, so the
        // copy is made first and the sheet reads that copy.
        provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
            guard let url, let copy = try? LAADriveBrowserView.copyForDrop(url) else { return }
            Task { @MainActor in droppedFile = DroppedFile(url: copy) }
        }
        return true
    }

    private func receive(_ url: URL) {
        do { droppedFile = DroppedFile(url: try Self.copyForDrop(url)) }
        catch { navigationError = "ドロップしたファイルを読み込めませんでした。" }
    }

    /// Copies a dropped file (which may be another app's, security-scoped)
    /// beside the upload's own temporary files, so the sheet can read it.
    private nonisolated static func copyForDrop(_ url: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DriveDrop-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        let target = folder.appendingPathComponent(name)
        do { try FileManager.default.copyItem(at: url, to: target) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return target
    }

    private func reload(_ requested: LoadKey, debounce: Bool) async {
        guard !Task.isCancelled, key == requested else { return }
        if let previous = displayedKey,
           previous.revision != requested.revision || previous.section != requested.section ||
           previous.folderID != requested.folderID || previous.search != requested.search || previous.fileType != requested.fileType || previous.order != requested.order {
            controller.invalidate()
        }
        waiting = controller.items.isEmpty
        displayedKey = requested
        navigationError = nil
        do {
            if debounce && !requested.search.isEmpty { try await Task.sleep(for: .milliseconds(350)) }
            try Task.checkCancellation()
            guard key == requested else { return }
            waiting = false
            let query = LAADriveBrowseQuery(section: requested.section, folderID: requested.folderID, search: requested.search, fileType: requested.fileType, order: requested.order)
            await controller.reload(query, cached: cached(query), using: load)
        } catch is CancellationError {
            if key == requested { waiting = false }
        } catch { waiting = false }
    }
}

private struct LAADriveSearchPlacement: ViewModifier {
    let desktop: Bool
    @Binding var query: String

    @ViewBuilder func body(content: Content) -> some View {
        if desktop {
            content
        } else {
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                               prompt: Text(verbatim: "検索"))
        }
    }
}

private extension LAADriveBrowseSection {
    var title: String {
        switch self {
        case .my: return String("マイドライブ")
        case .shared: return String("共有ドライブ")
        case .sharedWithMe: return String("共有アイテム")
        case .recent: return String("最近")
        case .starred: return String("スター付き")
        }
    }
}

@MainActor
struct LAADriveBrowserThumbnail: View {
    let entry: LAADriveListingItem
    let revision: Int
    let load: LAADriveBrowserView.ThumbnailLoader
    @State private var image: UIImage?

    private struct Key: Equatable {
        let revision: Int
        let id: String
        let version: String?
        let hasThumbnail: Bool?
    }
    private var key: Key {
        .init(revision: revision, id: entry.id, version: entry.thumbnailVersion ?? entry.version, hasThumbnail: entry.hasThumbnail)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: LAARadius.card).fill(LAAColor.subtleSurface)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: LAARadius.card))
            } else {
                Image(systemName: entry.item.kind == "shortcut" ? "arrow.turn.up.right" : entry.item.symbol)
                    .laaTextStyle(.body).foregroundStyle(LAAColor.link)
            }
        }
        .task(id: key) {
            image = nil
            guard entry.hasThumbnail == true else { return }
            image = LAADriveDecodedThumbnails.value(entry: entry, revision: revision)
            if image != nil { return }
            do {
                guard let data = try await load(entry), data.count <= 2 * 1024 * 1024 else { return }
                try Task.checkCancellation()
                let decoded = await Task.detached(priority: .utility) { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 480,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary)
                }.value
                try Task.checkCancellation()
                guard let thumbnail = decoded else { return }
                image = UIImage(cgImage: thumbnail)
                if let image { LAADriveDecodedThumbnails.insert(image, entry: entry, revision: revision) }
            } catch { }
        }
        .onDisappear { image = nil }
    }
}
@MainActor enum LAADriveDecodedThumbnails {
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.countLimit = 100; cache.totalCostLimit = 16 * 1024 * 1024; return cache
    }()
    private static func key(_ entry: LAADriveListingItem, _ revision: Int) -> NSString {
        "\(revision):\(entry.id):\(entry.thumbnailVersion ?? entry.version ?? "none")" as NSString
    }
    static func value(entry: LAADriveListingItem, revision: Int) -> UIImage? {
        guard entry.hasThumbnail == true, entry.thumbnailVersion ?? entry.version != nil else { return nil }
        return images.object(forKey: key(entry, revision))
    }
    static func invalidate(entry: LAADriveListingItem, revision: Int) { images.removeObject(forKey: key(entry, revision)) }
    static func insert(_ image: UIImage, entry: LAADriveListingItem, revision: Int) {
        guard entry.thumbnailVersion ?? entry.version != nil else { return }
        images.setObject(image, forKey: key(entry, revision), cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
    }
    static func removeAll() { images.removeAllObjects() }
}
#endif
