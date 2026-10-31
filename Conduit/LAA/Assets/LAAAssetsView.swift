#if LAA_BUILD
import SwiftUI

private struct LAADriveSelection: Hashable, Identifiable {
    let entry: LAADriveListingItem
    let images: [LAADriveItem]
    var id: String { entry.id }
}

struct LAAAssetsView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let onRequestSettings: () -> Void
    @State private var studioSelected = false
    private let initialStudioSection: Int
    @State private var showPairing = false
    @State private var selected: LAADriveSelection?
    @State private var thumbnailCache = LAADriveThumbnailCache()
    @State private var folderTask: Task<Void, Never>?
    @State private var folderPlan: LAADriveOfflineFolderPlan?
    @State private var confirmFolder = false
    @State private var folderMessage: String?

    init(onRequestSettings: @escaping () -> Void, initialStudioSelected: Bool = false, initialStudioSection: Int = 0) {
        self.onRequestSettings = onRequestSettings
        self.initialStudioSection = initialStudioSection
        _studioSelected = State(initialValue: initialStudioSelected)
    }

    var body: some View {
        ZStack {
            LAAColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    heading
                    segments
                    if studioSelected {
                        LAAStudioHomeView(initialSection: initialStudioSection)
                    } else if LAADriveData.available(bridge) {
                        NavigationLink("Saved offline") { LAADriveOfflineScreen() }
                            .accessibilityIdentifier("laa.drive.offline.list")
                        if folderTask != nil {
                            HStack {
                                ProgressView(folderMessage ?? "Preparing folder")
                                Button("Cancel") { folderTask?.cancel() }
                            }
                        } else if let folderMessage {
                            Text(verbatim: folderMessage).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                        LAADriveBrowserView(revision: bridge.revision, load: { query in
                            try await LAADriveData.listingPage(query, bridge: bridge)
                        }, loadThumbnail: { entry in
                            try await thumbnail(entry)
                        }, resolveShortcut: { entry, visited in
                            try await LAADriveShortcutResolver.resolve(entry, visitedFolderIDs: visited) { id in
                                try await LAADriveData.listingMetadata(id, bridge: bridge)
                            }
                        }, errorMessage: LAADrivePresentation.message, open: { entry, images in
                            selected = .init(entry: entry, images: images)
                        }, saveFolder: { entry in
                            planFolder(entry)
                        })
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { LAASettingsButton(action: onRequestSettings) }
        }
        .tint(LAAColor.link)
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .navigationDestination(item: $selected) { selected in
            LAADriveDetailView(item: selected.entry.item, webViewURL: selected.entry.safeWebViewURL, images: selected.images)
        }
        .onChange(of: bridge.revision) { _, _ in
            selected = nil
            folderTask?.cancel()
            folderPlan = nil
            confirmFolder = false
            Task { await thumbnailCache.removeAll() }
        }
        .onDisappear { folderTask?.cancel() }
        .confirmationDialog("Save this folder offline?", isPresented: $confirmFolder, titleVisibility: .visible) {
            Button("Save files") { if let folderPlan { saveFolder(folderPlan) } }
            Button("Cancel", role: .cancel) { folderPlan = nil }
        } message: {
            if let folderPlan {
                Text("\(folderPlan.files.count) files · at least \(ByteCountFormatter.string(fromByteCount: folderPlan.knownBytes, countStyle: .file)). \(folderPlan.unknownSizeCount) PDF exports have unknown size; \(folderPlan.issues.count) items or pages could not be included. Existing saved copies are kept if saving fails.")
            }
        }
    }

    private func planFolder(_ entry: LAADriveListingItem) {
        guard folderTask == nil else { return }
        folderMessage = "Preparing folder"
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
            } catch is CancellationError { folderMessage = "Folder preparation cancelled." }
            catch { folderMessage = LAADriveOfflineOperations.message(error) }
            folderTask = nil
        }
    }

    private func saveFolder(_ plan: LAADriveOfflineFolderPlan) {
        guard folderTask == nil else { return }
        folderPlan = nil
        folderMessage = "Saving 0 of \(plan.files.count)"
        folderTask = Task {
            let result = await LAADriveOfflineFolder.save(plan) { entry in
                try await LAADriveOfflineOperations.shared.save(entry.item, bridge: bridge)
            } progress: { completed, total in
                folderMessage = "Saving \(completed) of \(total)"
            }
            let outcome = result.cancelled ? "Cancelled" : "Finished"
            folderMessage = "\(outcome): \(result.savedIDs.count) saved, \(result.failedIDs.count) failed, \(plan.issues.count) not included."
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
                segment(LAACopy.Assets.drive, selected: !studioSelected) { studioSelected = false }
                segment(LAACopy.Assets.inspiration, selected: false, action: {}).disabled(true)
                    .accessibilityHint(Text(verbatim: LAACopy.Assets.unavailable))
                segment(LAACopy.Assets.studio, selected: studioSelected) { studioSelected = true }
            }
        }
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
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
