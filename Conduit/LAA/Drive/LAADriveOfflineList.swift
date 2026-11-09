#if LAA_BUILD
import SwiftUI

/// Shows only the current pairing's explicit saves. Before opening a record,
/// the owner must recheck access when online, call recordCheck, and obtain the
/// verified local URL from the same LAADriveOfflineStore instance.
@MainActor
struct LAADriveOfflineList: View {
    let pairingID: String
    let records: [LAADriveOfflineRecord]
    let loading: Bool
    let busyIDs: Set<String>
    let error: String?
    let retry: () -> Void
    let open: (LAADriveOfflineRecord) -> Void
    let remove: (LAADriveOfflineRecord) -> Void

    init(pairingID: String, records: [LAADriveOfflineRecord], loading: Bool, busyIDs: Set<String>,
         error: String?, retry: @escaping () -> Void, open: @escaping (LAADriveOfflineRecord) -> Void,
         remove: @escaping (LAADriveOfflineRecord) -> Void) {
        self.pairingID = pairingID
        self.records = records
        self.loading = loading
        self.busyIDs = busyIDs
        self.error = error
        self.retry = retry
        self.open = open
        self.remove = remove
    }

    @State private var pendingRemoval: LAADriveOfflineRecord?
    @State private var confirmingRemoval = false
    @State private var showingAll = false

    private var visibleRecords: [LAADriveOfflineRecord] { records.filter { $0.pairingID == pairingID } }

    /// On the Mac the saved files share the Drive column, so a growing list
    /// would push the files below it out of view. A few rows stay, and one
    /// control opens the rest. The phone keeps its own long list.
    private var collapsedLimit: Int { 4 }
    private var collapsible: Bool { LAADeviceCopy.isMac && visibleRecords.count > collapsedLimit }
    private var shownRecords: [LAADriveOfflineRecord] {
        collapsible && !showingAll ? Array(visibleRecords.prefix(collapsedLimit)) : visibleRecords
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Text("Saved offline").laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                .accessibilityAddTraits(.isHeader)
            if let error {
                Text(verbatim: error).laaTextStyle(.body).foregroundStyle(LAAColor.attention)
                Button("Retry", action: retry).disabled(loading)
            }
            if loading && visibleRecords.isEmpty {
                ProgressView().accessibilityLabel("Loading saved files")
            } else if visibleRecords.isEmpty && error == nil {
                Text("No files saved offline.").laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
            } else {
                LazyVStack(spacing: LAASpacing.x2) {
                    ForEach(shownRecords) { record in row(record) }
                }
                if collapsible {
                    Button {
                        showingAll.toggle()
                    } label: {
                        Text(verbatim: showingAll ? "折りたたむ" : "すべて表示（\(visibleRecords.count)件）")
                            .laaTextStyle(.secondary)
                    }
                    .frame(minHeight: LAASpacing.minimumTouchTarget)
                    .accessibilityIdentifier("laa.drive.offline.showAll")
                }
            }
        }
        .alert("Remove saved copy?", isPresented: $confirmingRemoval, presenting: pendingRemoval) { record in
            Button("Remove", role: .destructive) { remove(record) }
            Button("Cancel", role: .cancel) { }
        } message: { record in
            Text(verbatim: LAADeviceCopy.shown(AppLocalization.string("The saved copy of \(record.name) will be removed from this iPhone. The file in Drive will not be changed.")))
        }
        .onChange(of: pairingID) { _, _ in
            confirmingRemoval = false
            pendingRemoval = nil
            showingAll = false
        }
    }

    private func row(_ record: LAADriveOfflineRecord) -> some View {
        let canOpen = record.access == .verified || record.access == .stale
        return HStack(spacing: LAASpacing.x2) {
            Button { open(record) } label: {
                HStack(alignment: .top, spacing: LAASpacing.x3) {
                    Image(systemName: symbol(record)).foregroundStyle(LAAColor.link)
                        .frame(width: 28).frame(minHeight: LAASpacing.minimumTouchTarget)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        Text(verbatim: record.name).laaTextStyle(.body).fontWeight(.semibold)
                            .foregroundStyle(LAAColor.text).fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: details(record)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: status(record)).laaTextStyle(.secondary)
                            .foregroundStyle(canOpen ? LAAColor.secondaryText : LAAColor.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Tapping a previously denied copy performs a fresh check; an
            // offline check still refuses it until access is restored online.
            .disabled(busyIDs.contains(record.id))
            .accessibilityIdentifier("laa.drive.offline.item.\(record.id)")
            if busyIDs.contains(record.id) {
                ProgressView().accessibilityLabel("Updating saved file")
                    .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
            } else {
                Button {
                    pendingRemoval = record
                    confirmingRemoval = true
                } label: {
                    Image(systemName: "trash")
                        .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
                }
                .accessibilityLabel(Text(verbatim: "\(record.name)の保存済みコピーを削除"))
                .accessibilityIdentifier("laa.drive.offline.remove.\(record.id)")
            }
        }
        .padding(LAASpacing.x3)
        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
    }

    private func details(_ record: LAADriveOfflineRecord) -> String {
        let size = ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file)
        return record.sourceFormat == .workspacePDF ? "PDFコピー · \(size)" : size
    }

    private func status(_ record: LAADriveOfflineRecord) -> String {
        let checked = record.verifiedAt.formatted(date: .abbreviated, time: .shortened)
        switch record.access {
        case .verified: return "最終確認 \(checked)"
        case .stale: return "古いコピー · 最終確認 \(checked)"
        case .denied: return "アクセスできません · 最終確認 \(checked)"
        case .missing: return "Driveで利用できません · 最終確認 \(checked)"
        case .unknown: return "権限を確認できません · 最終確認 \(checked)"
        }
    }

    private func symbol(_ record: LAADriveOfflineRecord) -> String {
        if record.mimeType.hasPrefix("image/") { return "photo" }
        if record.mimeType.hasPrefix("video/") || record.mimeType.hasPrefix("audio/") { return "play.rectangle" }
        return "doc.text"
    }
}
#endif
