#if LAA_BUILD
import SwiftUI

private struct LAADriveSelection: Hashable, Identifiable {
    let entry: LAADriveListingItem
    let images: [LAADriveItem]
    var id: String { entry.id }
}

struct LAAAssetsView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    let onRequestSettings: () -> Void
    @State private var showUpload = false
    @State private var uploadFolderID: String?
    @State private var driveRevision = 0
    @State private var studioSelected = false
    @ObservedObject private var linkRequest = LAAWorkLinkRequest.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let initialStudioSection: Int
    @State private var showPairing = false
    @State private var selected: LAADriveSelection?
    @State private var thumbnailCache = LAADriveThumbnailCache()
    @State private var folderTask: Task<Void, Never>?
    @State private var folderPlan: LAADriveOfflineFolderPlan?
    @State private var confirmFolder = false
    @State private var folderMessage: String?
    @Environment(\.laaDesktop) private var laaDesktop
    @State private var desktopSelected: LAADriveSelection?

    init(onRequestSettings: @escaping () -> Void, initialStudioSelected: Bool = false, initialStudioSection: Int = 0) {
        self.onRequestSettings = onRequestSettings
        self.initialStudioSection = initialStudioSection
        _studioSelected = State(initialValue: initialStudioSelected)
    }

    var body: some View {
        Group {
            if laaDesktop { desktopContent } else { phoneContent }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { LAASettingsButton(action: onRequestSettings) }
        }
        .tint(LAAColor.link)
        .sheet(isPresented: $showUpload) { LAADriveUpload(folderId: uploadFolderID) { driveRevision &+= 1 }.environmentObject(bridge) }
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .navigationDestination(item: $selected) { selected in
            LAADriveDetailView(item: selected.entry.item, webViewURL: selected.entry.safeWebViewURL, images: selected.images)
        }
        .onChange(of: bridge.revision) { _, _ in
            selected = nil
            desktopSelected = nil
            folderTask?.cancel()
            folderPlan = nil
            confirmFolder = false
            Task { await thumbnailCache.removeAll() }
        }
        .onDisappear { folderTask?.cancel() }
        // A Drive link (laa://assets) opens the Studio tab on its Drive page.
        .onChange(of: linkRequest.generation) { _, _ in
            if linkRequest.url?.host == "assets" { studioSelected = false }
        }
        .confirmationDialog("Save this folder offline?", isPresented: $confirmFolder, titleVisibility: .visible) {
            Button("Save files") { if let folderPlan { saveFolder(folderPlan) } }
            Button("Cancel", role: .cancel) { folderPlan = nil }
        } message: {
            if let folderPlan {
                let minimumSpace = ByteCountFormatter.string(fromByteCount: folderPlan.knownBytes, countStyle: .file)
                Text("Files: \(folderPlan.files.count)") +
                Text(verbatim: "\n") + Text("Minimum space: \(minimumSpace)") +
                Text(verbatim: "\n") + Text("Items or pages not included: \(folderPlan.issues.count)") +
                Text(verbatim: "\n") + Text("Existing saved copies are kept if saving fails.")
            }
        }
    }

    private var phoneContent: some View {
        ZStack {
            LAAColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    heading
                    segments
                    if studioSelected {
                        LAAStudioHomeView(initialSection: initialStudioSection)
                    } else if LAADriveData.available(bridge) {
                        offlineEntry
                        driveBrowser
                    } else {
                        connection
                    }
                }
                .padding(.horizontal, LAASpacing.horizontal)
                .padding(.vertical, LAASpacing.x4)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Desktop (Mac) list and preview

    /// The Mac shell gives Drive its own sidebar entry, so the phone's
    /// Studio/Drive segment bar has nothing left to switch here.
    private var desktopContent: some View {
        LAAMacListDetail(listWidth: LAADesktopMetrics.listIdealWidth) {
            desktopList
        } detail: {
            desktopDetail
        }
        .background(LAAColor.background.ignoresSafeArea())
    }

    private var desktopList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                LAATabHeading(title: LAACopy.Assets.drive, identifier: "laa.assets.title")
                if LAADriveData.available(bridge) {
                    offlineEntry
                    driveBrowser
                } else {
                    connection
                }
            }
            .padding(.horizontal, LAASpacing.x4)
            .padding(.vertical, LAASpacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var desktopDetail: some View {
        if let desktopSelected {
            LAADriveDetailView(item: desktopSelected.entry.item,
                               webViewURL: desktopSelected.entry.safeWebViewURL,
                               images: desktopSelected.images,
                               contentMaxWidth: LAADesktopMetrics.documentWidth,
                               usesNavigationTitle: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LAAMacEmptyDetail(symbol: "folder", title: "ファイルを選ぶ",
                              message: "左の一覧からファイルを選ぶと、ここにプレビューと情報を表示します。")
        }
    }

    @ViewBuilder private var offlineEntry: some View {
        NavigationLink("Saved offline") { LAADriveOfflineScreen() }
            .accessibilityIdentifier("laa.drive.offline.list")
        if folderTask != nil {
            HStack {
                ProgressView(folderMessage ?? AppLocalization.string("Preparing…"))
                Button("Cancel") { folderTask?.cancel() }
            }
        } else if let folderMessage {
            Text(verbatim: folderMessage).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }
    }

    private var driveBrowser: some View {
        LAADriveBrowserView(revision: bridge.revision, refreshID: driveRevision, cached: { query in
            LAADriveData.cachedListing(query, bridge: bridge)
        }, upload: { folderID in uploadFolderID = folderID; showUpload = true }, load: { query in
            try await LAADriveData.listingPage(query, bridge: bridge)
        }, loadThumbnail: { entry in
            try await thumbnail(entry)
        }, resolveShortcut: { entry, visited in
            try await LAADriveShortcutResolver.resolve(entry, visitedFolderIDs: visited) { id in
                try await LAADriveData.listingMetadata(id, bridge: bridge)
            }
        }, errorMessage: LAADrivePresentation.message, open: { entry, images in
            if laaDesktop {
                desktopSelected = .init(entry: entry, images: images)
            } else {
                selected = .init(entry: entry, images: images)
            }
        }, saveFolder: { entry in
            planFolder(entry)
        }, desktop: laaDesktop, selectedID: desktopSelected?.id)
    }

    private func planFolder(_ entry: LAADriveListingItem) {
        guard folderTask == nil else { return }
        folderMessage = AppLocalization.string("Preparing…")
        let revision = bridge.revision
        folderTask = Task {
            do {
                let plan = try await LAADriveOfflineFolder.plan(rootID: entry.id) { id, cursor in
                    try await LAADriveData.listingPage(.init(section: .my, folderID: id, cursor: cursor), bridge: bridge)
                }
                try Task.checkCancellation()
                guard bridge.revision == revision else { throw CancellationError() }
                folderPlan = plan
                folderMessage = nil
                confirmFolder = true
            } catch is CancellationError { folderMessage = AppLocalization.string("Cancelled") }
            catch { folderMessage = LAADriveOfflineOperations.message(error) }
            folderTask = nil
        }
    }

    private func saveFolder(_ plan: LAADriveOfflineFolderPlan) {
        guard folderTask == nil else { return }
        folderPlan = nil
        folderMessage = "\(AppLocalization.string("Saving offline")) 0 / \(plan.files.count)"
        folderTask = Task {
            let result = await LAADriveOfflineFolder.save(plan) { entry in
                try await LAADriveOfflineOperations.shared.save(entry.item, bridge: bridge)
            } progress: { completed, total in
                folderMessage = "\(AppLocalization.string("Saving offline")) \(completed) / \(total)"
            }
            let outcome = result.cancelled ? AppLocalization.string("Cancelled") : AppLocalization.string("Finished")
            let saved = AppLocalization.string("Saved")
            let failed = AppLocalization.string("Failed")
            let omitted = AppLocalization.string("Items or pages not included: \(plan.issues.count)")
            folderMessage = "\(outcome) · \(saved) \(result.savedIDs.count) · \(failed) \(result.failedIDs.count) · \(omitted)"
            folderTask = nil
        }
    }

    private func thumbnail(_ entry: LAADriveListingItem) async throws -> Data? {
        let pairingID = bridge.deviceID
        let revision = bridge.revision
        let key = pairingID.flatMap { LAADriveThumbnailKey(pairingID: $0, fileID: entry.id, version: entry.thumbnailVersion) }
        if let cached = await thumbnailCache.value(for: key) {
            guard bridge.revision == revision, bridge.deviceID == pairingID else { throw CancellationError() }
            return cached
        }
        do {
            let data = try await bridge.driveThumbnail(id: entry.id)
            guard bridge.revision == revision, bridge.deviceID == pairingID else { throw CancellationError() }
            await thumbnailCache.insert(data, for: key)
            return data
        } catch {
            if let error = error as? LAABridgeHTTPError, [403, 404].contains(error.status), let pairingID {
                await thumbnailCache.invalidate(pairingID: pairingID, fileID: entry.id)
            }
            throw error
        }
    }

    /// The Studio tab's own title, like the other tabs' headings.
    private var heading: some View {
        LAATabHeading(title: LAATab.studio.title, identifier: "laa.assets.title")
    }

    /// Studio and Drive as the tab's two pages, in the Work tab's pill style.
    private var segments: some View {
        HStack(spacing: LAASpacing.x2) {
            segment(LAACopy.Assets.studio, symbol: "sparkles.rectangle.stack", selected: studioSelected,
                    identifier: "studio.section.studio") { studioSelected = true }
            segment(LAACopy.Assets.drive, symbol: "folder", selected: !studioSelected,
                    identifier: "studio.drive") { studioSelected = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.segment")
    }

    @ViewBuilder
    private func segment(_ title: String, symbol: String, selected: Bool, identifier: String,
                         action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
                .laaTextStyle(.secondary)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? LAAColor.link : LAAColor.secondaryText)
                .padding(.horizontal, LAASpacing.x4)
                .frame(minHeight: LAASpacing.minimumTouchTarget)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
        if #available(iOS 26.0, *), !reduceTransparency {
            button.glassEffect(.regular.tint(selected ? LAAColor.selectionFill : .clear).interactive(), in: .capsule)
        } else {
            button.background(selected ? LAAColor.selectionFill : LAAColor.surface, in: Capsule())
        }
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
}
#endif
