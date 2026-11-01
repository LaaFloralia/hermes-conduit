#if LAA_BUILD
import AVFoundation
import PDFKit
import SwiftUI
import UIKit

private struct LAADriveOfflineSelection: Identifiable {
    let id = UUID()
    let opened: LAADriveOfflineOpen
}

@MainActor
struct LAADriveOfflineScreen: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @State private var records: [LAADriveOfflineRecord] = []
    @State private var loading = true
    @State private var busy: Set<String> = []
    @State private var error: String?
    @State private var selection: LAADriveOfflineSelection?
    private let operations = LAADriveOfflineOperations.shared

    var body: some View {
        ScrollView {
            LAADriveOfflineList(pairingID: (try? operations.pairing(bridge)) ?? "", records: records,
                                loading: loading, busyIDs: busy, error: error,
                                retry: { Task { await reload() } },
                                open: { record in Task { await open(record) } },
                                remove: { record in Task { await remove(record) } })
                .padding(LAASpacing.horizontal)
        }
        .background(LAAColor.background.ignoresSafeArea())
        .navigationTitle("Saved offline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: bridge.revision) { selection = nil; await reload() }
        .sheet(item: $selection, onDismiss: { Task { await reload() } }) { selected in
            NavigationStack { LAADriveOfflinePreview(opened: selected.opened).environmentObject(bridge) }
        }
    }

    private func reload() async {
        loading = true; error = nil
        do { records = try await operations.records(bridge: bridge) }
        catch is CancellationError { }
        catch { records = []; self.error = LAADriveOfflineOperations.message(error) }
        loading = false
    }

    private func open(_ record: LAADriveOfflineRecord) async {
        guard busy.insert(record.id).inserted else { return }
        defer { busy.remove(record.id) }
        error = nil
        do { selection = .init(opened: try await operations.open(record, bridge: bridge)) }
        catch is CancellationError { }
        catch { self.error = LAADriveOfflineOperations.message(error); await reloadPreservingError() }
    }

    private func remove(_ record: LAADriveOfflineRecord) async {
        guard busy.insert(record.id).inserted else { return }
        defer { busy.remove(record.id) }
        error = nil
        do { try await operations.remove(record, bridge: bridge); await reload() }
        catch is CancellationError { }
        catch { self.error = LAADriveOfflineOperations.message(error) }
    }

    private func reloadPreservingError() async {
        let message = error
        await reload()
        if let message { error = message }
    }
}

private struct LAADriveShareSelection: Identifiable {
    let file: LAADriveShareFile
    var id: UUID { file.id }
}

@MainActor
private struct LAADriveOfflinePreview: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let opened: LAADriveOfflineOpen
    private let operations = LAADriveOfflineOperations.shared
    @State private var image: UIImage?
    @State private var document: PDFDocument?
    @State private var error: String?
    @State private var share: LAADriveShareSelection?
    @State private var activeShareID: UUID?
    @State private var sharing = false
    @State private var accessLost = false

    private var record: LAADriveOfflineRecord { opened.record }
    private var media: Bool { record.mimeType.hasPrefix("video/") || record.mimeType.hasPrefix("audio/") }

    var body: some View {
        VStack(spacing: LAASpacing.x3) {
            Text(verbatim: status).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                .padding(.horizontal, LAASpacing.horizontal)
            if let error, media && !accessLost {
                Text(verbatim: error).foregroundStyle(LAAColor.attention)
            }
            if accessLost {
                Text(verbatim: error ?? "Access to this saved file is no longer available.")
                    .foregroundStyle(LAAColor.attention)
            } else if media {
                LAADriveOfflinePlayer(opened: opened, bridge: bridge)
            } else if let image {
                LAADriveZoomImage(image: image)
            } else if let document {
                LAADrivePDF(document: document)
            } else if let error {
                Text(verbatim: error).foregroundStyle(LAAColor.attention)
            } else { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LAAColor.background.ignoresSafeArea())
        .navigationTitle(Text(verbatim: record.name)).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Share") { Task { await prepareShare() } }.disabled(sharing || accessLost)
            }
        }
        .task {
            if !media { loadDocument() }
            await monitorDocument()
        }
        .onChange(of: bridge.revision) { _, _ in
            accessLost = true
            image = nil; document = nil
            error = "The Bridge connection changed. Reopen this saved file."
        }
        .onDisappear { if share == nil { releaseShare() } }
        .sheet(item: $share, onDismiss: releaseShare) { selected in
            LAADriveShareSheet(items: [selected.file.url], onComplete: releaseShare)
        }
    }

    private var status: String {
        let checked = record.verifiedAt.formatted(date: .abbreviated, time: .shortened)
        let age = record.access == .stale ? "Older copy · " : ""
        return "\(age)Last verified \(checked)" + (opened.checkedOnline ? "" : " · Offline")
    }

    private func loadDocument() {
        if record.mimeType.hasPrefix("image/") {
            guard record.size <= LAADriveContent.previewLimit,
                  let data = try? Data(contentsOf: opened.url), let value = UIImage(data: data) else {
                error = LAACopy.Drive.invalidPreview; return
            }
            image = value
        } else if record.mimeType == "application/pdf", let value = PDFDocument(url: opened.url) {
            document = value
        } else { error = LAACopy.Drive.invalidPreview }
    }

    private func monitorDocument() async {
        guard !media else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
                try await operations.verify(record, bridge: bridge)
            } catch is CancellationError { return }
            catch {
                if let failure = error as? LAADriveOfflineError,
                   failure == .forbidden || failure == .notFound || failure == .accessChanged || failure == .permissionUnknown {
                    self.error = LAADriveOfflineOperations.message(error)
                    accessLost = true; image = nil; document = nil
                    return
                }
            }
        }
    }

    private func prepareShare() async {
        guard !sharing else { return }
        sharing = true
        defer { sharing = false }
        do {
            // Check again immediately before making an explicit share copy.
            let current = try await operations.open(record, bridge: bridge)
            let file = try await operations.shares.prepare(file: current.url, name: current.record.name,
                                                           mimeType: current.record.mimeType)
            activeShareID = file.id
            share = LAADriveShareSelection(file: file)
        } catch { self.error = LAADriveOfflineOperations.message(error) }
    }

    private func releaseShare() {
        guard let id = activeShareID else { return }
        activeShareID = nil
        share = nil
        Task { try? await operations.shares.release(id) }
    }
}

@MainActor
private struct LAADriveOfflinePlayer: View {
    @StateObject private var owner: LAADrivePlayerOwner
    let opened: LAADriveOfflineOpen
    let bridge: LAABridgeSession

    init(opened: LAADriveOfflineOpen, bridge: LAABridgeSession) {
        self.opened = opened; self.bridge = bridge
        let item = LAADriveOfflineOperations.shared.playbackItem(opened.record)
        _owner = StateObject(wrappedValue: LAADrivePlayerOwner(item: item, bridge: bridge, studioPath: nil,
                                                               autoPlay: false, localURL: opened.url))
    }

    var body: some View {
        LAADrivePlayerContent(owner: owner)
            .onAppear {
                let record = opened.record
                owner.monitorAccess { try await LAADriveOfflineOperations.shared.verify(record, bridge: bridge) }
            }
    }
}
#endif
