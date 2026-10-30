#if LAA_BUILD
import SwiftUI

private struct AssetsLoadKey: Equatable {
    let revision: Int
    let query: String
    let folderID: String?
}

struct LAAAssetsView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onRequestSettings: () -> Void
    @State private var query = ""
    @State private var folders: [LAADriveItem] = []
    @State private var items: [LAADriveItem] = []
    @State private var cursor: String?
    @State private var seenCursors: Set<String> = []
    @State private var generation = 0
    @State private var filter: LAADriveFilter = .all
    @State private var error: String?
    @State private var loading = false
    @State private var showPairing = false
    @FocusState private var searchFocused: Bool

    private var key: AssetsLoadKey { .init(revision: bridge.revision, query: query, folderID: folders.last?.id) }
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] :
            [GridItem(.flexible(), spacing: LAASpacing.x2), GridItem(.flexible())]
    }

    var body: some View {
        ZStack {
            LAAColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    heading
                    segments
                    Text(verbatim: LAACopy.Assets.unavailable).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    if LAADriveData.available(bridge) {
                        searchField
                        if !folders.isEmpty {
                            Button { folders.removeLast(); query = "" } label: {
                                Label { Text(verbatim: LAACopy.Brain.back) } icon: { Image(systemName: "chevron.left") }
                            }.accessibilityIdentifier("laa.assets.back")
                        }
                        contents
                    } else {
                        connection
                    }
                }
                .padding(.horizontal, LAASpacing.horizontal)
                .padding(.vertical, LAASpacing.x4)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await reload(key) }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onRequestSettings) { Image(systemName: "gearshape") }
                    .accessibilityLabel(Text(verbatim: LAACopy.Brain.settings))
            }
        }
        .tint(LAAColor.link)
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .task(id: key) { await reload(key) }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: "LAA").laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.link)
            Text(verbatim: LAACopy.Assets.title).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("laa.assets.title")
            Text(verbatim: LAACopy.Assets.subtitle).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }
    }

    private var segments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LAASpacing.x2) {
                segment(LAACopy.Assets.drive, selected: true)
                segment(LAACopy.Assets.inspiration, selected: false).disabled(true)
                    .accessibilityHint(Text(verbatim: LAACopy.Assets.unavailable))
                segment(LAACopy.Assets.studio, selected: false).disabled(true)
                    .accessibilityHint(Text(verbatim: LAACopy.Assets.unavailable))
            }
        }
    }

    private func segment(_ title: String, selected: Bool) -> some View {
        Button {} label: {
            Text(verbatim: title).laaTextStyle(.secondary).fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? LAAColor.filledButtonText : LAAColor.secondaryText)
                .padding(.horizontal, LAASpacing.x4).padding(.vertical, LAASpacing.x2)
                .background(selected ? LAAColor.filledButton : LAAColor.subtleSurface,
                            in: RoundedRectangle(cornerRadius: LAARadius.selectionChip))
                .frame(minHeight: LAASpacing.minimumTouchTarget)
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var searchField: some View {
        HStack(spacing: LAASpacing.x3) {
            Image(systemName: "magnifyingglass").foregroundStyle(LAAColor.secondaryText)
            TextField(text: $query) { Text(verbatim: LAACopy.Assets.search) }
                .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                .accessibilityIdentifier("laa.assets.search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel(Text(verbatim: LAACopy.Brain.clearSearch))
            }
        }
        .laaTextStyle(.body).padding(.horizontal, LAASpacing.x4)
        .frame(minHeight: LAASpacing.minimumTouchTarget)
        .background(LAAColor.subtleSurface, in: RoundedRectangle(cornerRadius: LAARadius.card))
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Text(verbatim: bridge.status == .keychainError ? LAABridgeError.keychain.japaneseText :
                 bridge.status == .revoked || bridge.status == .unauthorized ? LAABridgeError.revoked.japaneseText : LAACopy.bridgeNotPairedBody)
            if bridge.status != .keychainError {
                Button { showPairing = true } label: { Text(verbatim: LAACopy.Brain.connect) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("laa.assets.pair")
            }
        }.laaTextStyle(.body).foregroundStyle(LAAColor.text)
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            HStack {
                Text(verbatim: (folders.last?.name ?? LAACopy.Assets.files).uppercased())
                    .laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    ForEach(LAADriveFilter.allCases, id: \.self) { option in
                        Button(option.title) { filter = option }
                            .accessibilityAddTraits(option == filter ? .isSelected : [])
                    }
                } label: {
                    Text(verbatim: "\(LAACopy.Assets.filter): \(filter.title)").laaTextStyle(.secondary)
                }
                    .accessibilityIdentifier("laa.assets.filter")
            }
            if let error {
                Text(verbatim: error).laaTextStyle(.body).foregroundStyle(LAAColor.attention)
                Button(LAACopy.Brain.retry) { Task { await reload(key) } }
            }
            if loading && items.isEmpty {
                ProgressView().accessibilityLabel(Text(verbatim: LAACopy.loading))
            } else if items.filter(filter.contains).isEmpty && error == nil {
                Text(verbatim: LAACopy.Assets.empty).laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
            } else if !items.filter(filter.contains).isEmpty {
                LazyVGrid(columns: columns, spacing: LAASpacing.x2) {
                    ForEach(items.filter(filter.contains)) { item in card(item) }
                }
            }
            if filter != .all { Text(verbatim: LAACopy.Assets.loadedOnly).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
            if cursor != nil {
                Button(LAACopy.Assets.loadMore) { Task { await more(key) } }
                    .disabled(loading).accessibilityIdentifier("laa.assets.more")
            }
        }.padding(.top, LAASpacing.x3)
    }

    private func card(_ item: LAADriveItem) -> some View {
        Group {
            if item.isFolder {
                Button { folders.append(item); query = "" } label: { cardContent(item) }
            } else {
                NavigationLink { LAADriveDetailView(item: item) } label: { cardContent(item) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("laa.assets.item.\(item.id)")
    }

    private func cardContent(_ item: LAADriveItem) -> some View {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                ZStack {
                    RoundedRectangle(cornerRadius: LAARadius.card).fill(LAAColor.subtleSurface)
                    if let url = LAADriveThumbnail.safeURL(item.thumbnailLink) {
                        AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: {
                            Image(systemName: item.symbol).foregroundStyle(LAAColor.link)
                        }.clipShape(RoundedRectangle(cornerRadius: LAARadius.card))
                    } else {
                        Image(systemName: item.symbol).laaTextStyle(.body).foregroundStyle(LAAColor.link)
                    }
                }.aspectRatio(1, contentMode: .fit)
                Text(verbatim: item.name).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                Text(verbatim: item.kindTitle).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            .padding(LAASpacing.x3).frame(maxWidth: .infinity, alignment: .leading)
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
    }

    @MainActor private func reload(_ requested: AssetsLoadKey) async {
        generation += 1
        let requestGeneration = generation
        items = []; cursor = nil; seenCursors = []; error = nil
        guard LAADriveData.available(bridge) else { loading = false; return }
        guard let path = LAADriveData.path(query: requested.query, folderID: requested.folderID, cursor: nil) else {
            error = LAACopy.Assets.searchTooLong; loading = false; return
        }
        loading = true
        do {
            if !requested.query.isEmpty { try await Task.sleep(for: .milliseconds(350)) }
            let page = try await LAADriveData.page(path: path, bridge: bridge)
            try Task.checkCancellation()
            guard key == requested, generation == requestGeneration else { return }
            items = page.items; cursor = page.nextCursor; loading = false
        } catch is CancellationError {
            if key == requested, generation == requestGeneration { loading = false }
        }
        catch { guard key == requested, generation == requestGeneration else { return }; self.error = message(error); loading = false }
    }

    @MainActor private func more(_ requested: AssetsLoadKey) async {
        guard !loading, let previous = cursor,
              let path = LAADriveData.path(query: requested.query, folderID: requested.folderID, cursor: previous) else { return }
        let requestGeneration = generation
        loading = true; error = nil
        do {
            let page = try await LAADriveData.page(path: path, bridge: bridge)
            try Task.checkCancellation()
            guard key == requested, generation == requestGeneration, cursor == previous else { return }
            var existing = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { existing.insert($0.id).inserted })
            seenCursors.insert(previous)
            if let next = page.nextCursor, seenCursors.contains(next) {
                cursor = nil; error = LAABridgeError.invalidResponse.japaneseText
            } else { cursor = page.nextCursor }
            loading = false
        } catch is CancellationError {
            if key == requested, generation == requestGeneration { loading = false }
        }
        catch { guard key == requested, generation == requestGeneration else { return }; self.error = message(error); loading = false }
    }

    private func message(_ error: Error) -> String {
        if let error = error as? LAABridgeHTTPError {
            if error.code == "drive_not_configured" { return LAACopy.Assets.configureDrive }
            if error.code == "insufficient_scope" { return LAACopy.Assets.scope }
            return error.legacyError.japaneseText
        }
        return (error as? LAABridgeError)?.japaneseText ?? LAABridgeError.invalidResponse.japaneseText
    }
}
#endif
