#if LAA_BUILD
import SwiftUI

private struct LAADriveSelection: Hashable, Identifiable {
    let entry: LAADriveListingItem
    let images: [LAADriveItem]
    var poster: UIImage? = nil
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
    @State private var requestGeneration = 0
    @ObservedObject private var linkRequest = LAAWorkLinkRequest.shared
    private let initialStudioSection: Int
    @State private var showPairing = false
    @State private var selected: LAADriveSelection?
    @State private var thumbnailCache = LAADriveThumbnailCache(diskDirectory: LAADriveThumbnailCache.defaultDirectory())
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
            if laaDesktop && !studioSelected { desktopContent } else { phoneContent }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !studioSelected {
                    Button {
                        requestGeneration &+= 1
                        studioSelected = true
                    } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .accessibilityLabel("制作を依頼").accessibilityIdentifier("laa.assets.new-request")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { LAASettingsButton(action: onRequestSettings) }
        }
        .tint(LAAColor.link)
        .sheet(isPresented: $showUpload) { LAADriveUpload(folderId: uploadFolderID) { driveRevision &+= 1 }.environmentObject(bridge).laaSheetSize(.form) }
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .navigationDestination(item: $selected) { selected in
            if selected.entry.item.isMedia || selected.entry.item.isImage {
                LAADrivePreviewView(item: selected.entry.item, images: selected.images, poster: selected.poster)
            } else {
                LAADriveDetailView(item: selected.entry.item, webViewURL: selected.entry.safeWebViewURL, images: selected.images)
            }
        }
        .onChange(of: bridge.revision) { _, _ in
            selected = nil
            desktopSelected = nil
            folderTask?.cancel()
            folderPlan = nil
            confirmFolder = false
            LAADriveDecodedThumbnails.removeAll()
            Task { await thumbnailCache.removeAll() }
        }
        .onChange(of: studioSelected) { _, selected in
            if !selected { requestGeneration = 0 }
        }
        .onDisappear { folderTask?.cancel() }
        // A Drive link (laa://assets) opens the Studio tab on its Drive page.
        .onChange(of: linkRequest.generation) { _, _ in
            if linkRequest.url?.host == "assets" { studioSelected = false }
        }
        .confirmationDialog("このフォルダを端末に保存しますか？", isPresented: $confirmFolder, titleVisibility: .visible) {
            Button("ファイルを保存") { if let folderPlan { saveFolder(folderPlan) } }
            Button("キャンセル", role: .cancel) { folderPlan = nil }
        } message: {
            if let folderPlan {
                let minimumSpace = ByteCountFormatter.string(fromByteCount: folderPlan.knownBytes, countStyle: .file)
                Text("ファイル: \(folderPlan.files.count)") +
                Text(verbatim: "\n") + Text("必要な空き容量: \(minimumSpace)") +
                Text(verbatim: "\n") + Text("取得できなかった項目: \(folderPlan.issues.count)") +
                Text(verbatim: "\n") + Text("失敗した場合も、保存済みのファイルは残ります。")
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
                        LAAStudioHomeView(initialSection: initialStudioSection, requestGeneration: requestGeneration)
                    } else if LAADriveData.available(bridge) {
                        driveBrowser
                        if let folderMessage {
                            HStack {
                                Text(verbatim: folderMessage).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                if folderTask != nil { Button("キャンセル") { folderTask?.cancel() } }
                            }
                        }
                    } else {
                        connection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, LAASpacing.x4)
                .laaPageWidth()
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
                selected = .init(entry: entry, images: images, poster: LAADriveDecodedThumbnails.value(entry: entry, revision: bridge.revision))
            }
        }, saveFolder: { entry in
            planFolder(entry)
        }, saveFile: { entry in
            saveFile(entry)
        }, desktop: laaDesktop, selectedID: desktopSelected?.id)
    }

    private func saveFile(_ entry: LAADriveListingItem) {
        guard folderTask == nil else { return }
        folderTask = Task {
            do {
                try await LAADriveOfflineOperations.shared.save(entry.item, bridge: bridge)
                folderMessage = "この端末に保存しました"
            } catch is CancellationError { }
            catch { folderMessage = LAADriveOfflineOperations.message(error) }
            folderTask = nil
        }
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
        let key = pairingID.flatMap { LAADriveThumbnailKey(pairingID: $0, fileID: entry.id, version: entry.thumbnailVersion ?? entry.version) }
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
                LAADriveDecodedThumbnails.invalidate(entry: entry, revision: revision)
                await thumbnailCache.invalidate(pairingID: pairingID, fileID: entry.id)
            }
            throw error
        }
    }

    /// The Studio tab's own title, like the other tabs' headings.
    private var heading: some View {
        LAATabHeading(title: LAATab.studio.title, identifier: "laa.assets.title")
    }

    private var segments: some View {
        Picker("Studio", selection: $studioSelected) {
            Text("Studio").tag(true).accessibilityIdentifier("studio.section.studio")
            Text("Drive").tag(false).accessibilityIdentifier("studio.drive")
        }
        .pickerStyle(.segmented)
        .frame(minHeight: LAASpacing.minimumTouchTarget)
        .accessibilityIdentifier("studio.segment")
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Text(verbatim: bridge.status == .keychainError ? LAABridgeError.keychain.japaneseText :
                 bridge.status == .revoked || bridge.status == .unauthorized ? LAABridgeError.revoked.japaneseText : LAACopy.bridgeNotPairedBody)
            if bridge.status != .keychainError {
                Button { showPairing = true } label: { Text(verbatim: LAACopy.Brain.connect) }
                    .laaGlassButton(prominent: true).accessibilityIdentifier("laa.assets.pair")
            }
        }.laaTextStyle(.body).foregroundStyle(LAAColor.text)
    }
}
#endif
