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
    let saveFolder: (LAADriveListingItem) -> Void
    /// The Mac list shows files as rows with columns and keeps the selection
    /// visible while the detail column shows the file.
    var desktop = false
    var selectedID: String?

    init(revision: Int, refreshID: Int = 0, cached: @escaping (LAADriveBrowseQuery) -> LAADriveListingPage? = { _ in nil }, upload: @escaping (String?) -> Void = { _ in }, load: @escaping Loader, loadThumbnail: @escaping ThumbnailLoader,
         resolveShortcut: @escaping ShortcutLoader,
         errorMessage: @escaping (Error) -> String, open: @escaping (LAADriveListingItem, [LAADriveItem]) -> Void,
         saveFolder: @escaping (LAADriveListingItem) -> Void = { _ in },
         desktop: Bool = false, selectedID: String? = nil) {
        self.desktop = desktop
        self.selectedID = selectedID
        self.cached = cached; self.upload = upload
        self.revision = revision; self.refreshID = refreshID
        self.load = load
        self.loadThumbnail = loadThumbnail
        self.resolveShortcut = resolveShortcut
        self.errorMessage = errorMessage
        self.open = open
        self.saveFolder = saveFolder
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

    private enum Layout { case grid, list }
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
    }
    private var key: LoadKey {
        .init(revision: revision, refreshID: refreshID, section: section, folderID: folders.last?.id, search: search)
    }
    private var effectiveLayout: Layout { desktop ? .list : layout }

    private var columns: [GridItem] {
        if desktop {
            return [GridItem(.adaptive(minimum: LAADesktopMetrics.gridItemMinWidth), spacing: LAASpacing.x6)]
        }
        return dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] :
            [GridItem(.flexible(), spacing: LAASpacing.x2), GridItem(.flexible())]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            sections
            searchField
            if desktop {
                desktopBreadcrumb
            } else if let folder = folders.last {
                HStack {
                    Button {
                        folders.removeLast()
                        search = ""
                    } label: {
                        Label("Back to \(folders.dropLast().last?.item.name ?? section.title)", systemImage: "chevron.left")
                    }
                    .frame(minHeight: LAASpacing.minimumTouchTarget)
                    .accessibilityIdentifier("laa.drive.browser.back")
                    Spacer()
                    Button("Save folder") { saveFolder(folder) }
                        .frame(minHeight: LAASpacing.minimumTouchTarget)
                        .accessibilityHint("Estimate space before saving this folder offline.")
                    .accessibilityIdentifier("laa.drive.offline.folder")
                }
            }
            HStack {
                header
                Button { upload(folders.last?.id) } label: { Image(systemName: "plus") }
                    .frame(minWidth: 44, minHeight: 44).accessibilityLabel(Text(verbatim: "アップロード"))
            }
            results
        }
        .tint(LAAColor.link)
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
        }
        .onChange(of: key) { _, _ in cancelResolution() }
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
            .buttonStyle(.plain)
            ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(LAAColor.secondaryText)
                    .accessibilityHidden(true)
                Button { folders = Array(folders.prefix(index + 1)); search = "" } label: {
                    Text(verbatim: folder.item.name).laaTextStyle(.secondary).lineLimit(1)
                        .foregroundStyle(index == folders.count - 1 ? LAAColor.text : LAAColor.link)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if let folder = folders.last {
                Button("Save folder") { saveFolder(folder) }
                    .laaTextStyle(.secondary)
                    .frame(minHeight: LAASpacing.minimumTouchTarget)
                    .help("このフォルダをオフライン保存")
                    .accessibilityIdentifier("laa.drive.offline.folder")
            }
        }
        .frame(minHeight: LAASpacing.minimumTouchTarget)
    }

    @ViewBuilder private var sections: some View {
        if desktop {
            LAAMacFlowLayout(spacing: LAASpacing.x2) {
                ForEach(LAADriveBrowseSection.allCases, id: \.self) { option in
                    sectionChip(option)
                }
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LAASpacing.x2) {
                    ForEach(LAADriveBrowseSection.allCases, id: \.self) { option in
                        sectionChip(option)
                    }
                }
            }
        }
    }

    private func sectionChip(_ option: LAADriveBrowseSection) -> some View {
        Button {
            guard option != section else { return }
            section = option
            folders = []
            search = ""
            searchFocused = false
        } label: {
            Text(verbatim: option.title).laaTextStyle(.secondary)
                .fontWeight(option == section ? .semibold : .regular)
                .foregroundStyle(option == section ? LAAColor.filledButtonText : LAAColor.secondaryText)
                .padding(.horizontal, LAASpacing.x4).padding(.vertical, LAASpacing.x2)
                .background(option == section ? LAAColor.filledButton : LAAColor.subtleSurface,
                            in: RoundedRectangle(cornerRadius: LAARadius.selectionChip))
                .frame(minHeight: LAASpacing.minimumTouchTarget)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(option == section ? .isSelected : [])
        .accessibilityIdentifier("laa.drive.browser.section.\(option.rawValue)")
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            HStack(spacing: LAASpacing.x3) {
                Image(systemName: "magnifyingglass").foregroundStyle(LAAColor.secondaryText)
                    .accessibilityHidden(true)
                TextField("Search files", text: $search)
                    .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                    .accessibilityIdentifier("laa.drive.browser.search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Clear search")
                        .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
                }
            }
            .laaTextStyle(.body).padding(.horizontal, LAASpacing.x4)
            .frame(minHeight: LAASpacing.minimumTouchTarget)
            .background(LAAColor.subtleSurface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            if !search.isEmpty {
                Text(verbatim: searchScope).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
        }
    }

    private var searchScope: String {
        if !folders.isEmpty { return AppLocalization.string("Searching this folder only.") }
        if section == .my { return "マイドライブ全体を検索します。" }
        return AppLocalization.string("Searching \(section.title).")
    }

    private var header: some View {
        HStack {
            // The desktop breadcrumb already names the folder, so only the
            // actions are repeated here.
            if !desktop {
                Text(verbatim: folders.last?.item.name ?? section.title)
                    .laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            Button { Task { await reload(key, debounce: false) } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
            }
            .accessibilityLabel("Refresh files")
            .accessibilityIdentifier("laa.drive.browser.refresh")
            if !desktop {
                Button {
                    layout = layout == .grid ? .list : .grid
                } label: {
                    Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
                        .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
                }
                .accessibilityLabel(layout == .grid ? AppLocalization.string("Show list") : AppLocalization.string("Show grid"))
                .accessibilityIdentifier("laa.drive.browser.layout")
            }
        }
    }

    @ViewBuilder private var results: some View {
        if waiting || displayedKey != key || (controller.loading && controller.items.isEmpty) {
            ProgressView().accessibilityLabel("Loading files")
        } else {
            if let navigationError {
                Text(verbatim: navigationError).laaTextStyle(.body).foregroundStyle(LAAColor.attention)
            }
            if resolvingID != nil { ProgressView("Opening shortcut") }
            if let error = controller.error {
                Text(verbatim: (error as? LAADriveBrowseError) == .cursorExpired
                     ? AppLocalization.string("Results expired. Retry to reload from the beginning.") : errorMessage(error))
                    .laaTextStyle(.body).foregroundStyle(LAAColor.attention)
                Button("Retry") {
                    Task {
                        if controller.cursor != nil, !controller.items.isEmpty {
                            await controller.loadMore(using: load)
                        } else { await reload(key, debounce: false) }
                    }
                }
                .disabled(controller.loading)
            }
            if controller.items.isEmpty && controller.error == nil {
                Text("No items found.").laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
            }
            if controller.incompleteSearch == true {
                Text("Results may be incomplete.").laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            } else if controller.incompleteSearch == nil && controller.error == nil {
                Text("Could not confirm that these are all results.")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            if effectiveLayout == .grid {
                LazyVGrid(columns: columns, spacing: LAASpacing.x2) {
                    ForEach(controller.items) { entry in cell(entry, grid: true) }
                }
            } else {
                LazyVStack(spacing: desktop ? 0 : LAASpacing.x2) {
                    ForEach(controller.items) { entry in cell(entry, grid: false) }
                }
            }
            if controller.cursor != nil && controller.error == nil {
                Button("Load more") { Task { await controller.loadMore(using: load) } }
                    .disabled(controller.loading).accessibilityIdentifier("laa.drive.browser.more")
            }
            if controller.loading { ProgressView().accessibilityLabel("Loading more files") }
        }
    }

    @ViewBuilder private func cell(_ entry: LAADriveListingItem, grid: Bool) -> some View {
        if desktop {
            LAADriveDesktopRow(entry: entry, isSelected: selectedID == entry.id,
                               select: { select(entry) }, saveFolder: { saveFolder(entry) })
                .disabled(resolvingID != nil)
        } else {
        Button { select(entry) } label: {
            Group {
                if grid {
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        thumbnail(entry).aspectRatio(1, contentMode: .fit)
                        labels(entry)
                    }
                } else {
                    HStack(spacing: LAASpacing.x3) {
                        thumbnail(entry).frame(width: 56, height: 56)
                        labels(entry)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(LAAColor.secondaryText)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(LAASpacing.x3).frame(maxWidth: .infinity, alignment: .leading)
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
        }
        .buttonStyle(.plain)
        .disabled(resolvingID != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: entry.item.name))
        .accessibilityValue(Text(verbatim: kind(entry)))
        .accessibilityHint(entry.item.isFolder ? AppLocalization.string("Open folder") : entry.item.kind == "shortcut" ? AppLocalization.string("Open shortcut") : AppLocalization.string("Open file"))
        .accessibilityIdentifier("laa.drive.browser.item.\(entry.id)")
        .contextMenu {
            if entry.item.isFolder {
                Button("Save folder offline", systemImage: "arrow.down.circle") { saveFolder(entry) }
            }
        }
        }
    }

    private func labels(_ entry: LAADriveListingItem) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: entry.item.name).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: kind(entry)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
            var images = controller.items.map(\.item).filter(\.isImage)
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
        controller.invalidate()
        waiting = true
        displayedKey = requested
        navigationError = nil
        do {
            if debounce && !requested.search.isEmpty { try await Task.sleep(for: .milliseconds(350)) }
            try Task.checkCancellation()
            guard key == requested else { return }
            waiting = false
            let query = LAADriveBrowseQuery(section: requested.section, folderID: requested.folderID, search: requested.search)
            await controller.reload(query, cached: cached(query), using: load)
        } catch is CancellationError {
            if key == requested { waiting = false }
        } catch { waiting = false }
    }
}

private extension LAADriveBrowseSection {
    var title: String {
        switch self {
        case .my: return AppLocalization.string("My Drive")
        case .shared: return AppLocalization.string("Shared drives")
        case .sharedWithMe: return AppLocalization.string("Shared with me")
        case .recent: return AppLocalization.string("Recent")
        case .starred: return AppLocalization.string("Starred")
        }
    }
}

@MainActor
private struct LAADriveBrowserThumbnail: View {
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
        .init(revision: revision, id: entry.id, version: entry.thumbnailVersion, hasThumbnail: entry.hasThumbnail)
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
            do {
                guard let data = try await load(entry), data.count <= 2 * 1024 * 1024 else { return }
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 480,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return }
                try Task.checkCancellation()
                image = UIImage(cgImage: thumbnail)
            } catch { }
        }
        .onDisappear { image = nil }
    }
}
#endif
