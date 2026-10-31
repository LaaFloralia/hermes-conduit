#if LAA_BUILD
import ImageIO
import SwiftUI
import UIKit

/// The Assets screen supplies the authenticated loaders and opens files. The
/// browser owns only its section, folder path, search and presentation state.
@MainActor
struct LAADriveBrowserView: View {
    typealias Loader = LAADriveBrowseController.Loader
    typealias ThumbnailLoader = @MainActor (LAADriveListingItem) async throws -> Data?

    let revision: Int
    let load: Loader
    let loadThumbnail: ThumbnailLoader
    let errorMessage: (Error) -> String
    let open: (LAADriveListingItem) -> Void

    init(revision: Int, load: @escaping Loader, loadThumbnail: @escaping ThumbnailLoader,
         errorMessage: @escaping (Error) -> String, open: @escaping (LAADriveListingItem) -> Void) {
        self.revision = revision
        self.load = load
        self.loadThumbnail = loadThumbnail
        self.errorMessage = errorMessage
        self.open = open
    }

    @StateObject private var controller = LAADriveBrowseController()
    @State private var section: LAADriveBrowseSection = .my
    @State private var folders: [LAADriveListingItem] = []
    @State private var search = ""
    @State private var layout: Layout = .grid
    @State private var waiting = true
    @State private var displayedKey: LoadKey?
    @State private var navigationError: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum Layout { case grid, list }
    private struct LoadKey: Equatable {
        let revision: Int
        let section: LAADriveBrowseSection
        let folderID: String?
        let search: String
    }
    private var key: LoadKey {
        .init(revision: revision, section: section, folderID: folders.last?.id, search: search)
    }
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] :
            [GridItem(.flexible(), spacing: LAASpacing.x2), GridItem(.flexible())]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            sections
            searchField
            if !folders.isEmpty {
                Button {
                    folders.removeLast()
                    search = ""
                } label: {
                    Label("Back to \(folders.dropLast().last?.item.name ?? section.title)", systemImage: "chevron.left")
                }
                .frame(minHeight: LAASpacing.minimumTouchTarget)
                .accessibilityIdentifier("laa.drive.browser.back")
            }
            header
            results
        }
        .tint(LAAColor.link)
        .task(id: key) { [requested = key] in await reload(requested, debounce: true) }
        .onChange(of: revision) { _, _ in
            controller.invalidate()
            folders = []
            search = ""
            section = .my
        }
    }

    private var sections: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LAASpacing.x2) {
                ForEach(LAADriveBrowseSection.allCases, id: \.self) { option in
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
            }
        }
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
        if !folders.isEmpty { return "Searching this folder only." }
        if section == .my { return "Searching the top level of My Drive only." }
        return "Searching \(section.title)."
    }

    private var header: some View {
        HStack {
            Text(verbatim: folders.last?.item.name ?? section.title)
                .laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                layout = layout == .grid ? .list : .grid
            } label: {
                Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
                    .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
            }
            .accessibilityLabel(layout == .grid ? "Show list" : "Show grid")
            .accessibilityIdentifier("laa.drive.browser.layout")
        }
    }

    @ViewBuilder private var results: some View {
        if waiting || displayedKey != key || (controller.loading && controller.items.isEmpty) {
            ProgressView().accessibilityLabel("Loading files")
        } else {
            if let navigationError {
                Text(verbatim: navigationError).laaTextStyle(.body).foregroundStyle(LAAColor.attention)
            }
            if let error = controller.error {
                Text(verbatim: errorMessage(error)).laaTextStyle(.body).foregroundStyle(LAAColor.attention)
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
            if layout == .grid {
                LazyVGrid(columns: columns, spacing: LAASpacing.x2) {
                    ForEach(controller.items) { entry in cell(entry, grid: true) }
                }
            } else {
                LazyVStack(spacing: LAASpacing.x2) {
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

    private func cell(_ entry: LAADriveListingItem, grid: Bool) -> some View {
        Button {
            if entry.item.isFolder {
                guard !folders.contains(where: { $0.id == entry.id }) else {
                    navigationError = "This folder is already in the current path."
                    return
                }
                folders.append(entry)
                search = ""
                searchFocused = false
            } else { open(entry) }
        } label: {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: entry.item.name))
        .accessibilityValue(Text(verbatim: entry.item.kindTitle))
        .accessibilityHint(entry.item.isFolder ? "Open folder" : "Open file")
        .accessibilityIdentifier("laa.drive.browser.item.\(entry.id)")
    }

    private func labels(_ entry: LAADriveListingItem) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: entry.item.name).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: entry.item.kindTitle).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func thumbnail(_ entry: LAADriveListingItem) -> some View {
        LAADriveBrowserThumbnail(entry: entry, revision: revision, load: loadThumbnail)
            .accessibilityHidden(true)
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
            await controller.reload(.init(section: requested.section, folderID: requested.folderID,
                                          search: requested.search), using: load)
        } catch is CancellationError {
            if key == requested { waiting = false }
        } catch { waiting = false }
    }
}

private extension LAADriveBrowseSection {
    var title: String {
        switch self {
        case .my: return "My Drive"
        case .shared: return "Shared"
        case .recent: return "Recent"
        case .starred: return "Starred"
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
                Image(systemName: entry.item.symbol).laaTextStyle(.body).foregroundStyle(LAAColor.link)
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
