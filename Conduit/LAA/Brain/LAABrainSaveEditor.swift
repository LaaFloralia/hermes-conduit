#if LAA_BUILD
import SwiftUI
import UniformTypeIdentifiers

/// Original-note editing remains available only to the disposable simulator
/// fixture until the recovery UI and cross-device gate have been verified.
enum LAABrainEditingGate {
    static var enabled: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-laa-brain-local-fixture") && arguments.contains("-laa-brain-save-fixture")
        #else
        return false
        #endif
    }
}

private struct BrainSaveConflict {
    let other: String?
    let draft: String
    let afterExchange: Bool
}

struct LAABrainSaveEditor: View {
    @Environment(\.dismiss) private var dismiss
    let root: URL
    let path: String
    let didSave: () -> Void
    private let coordinator = LAABrainSaveCoordinator()
    @State private var snapshot: LAABrainSaveCoordinator.Snapshot?
    @State private var draft = ""
    @State private var conflict: BrainSaveConflict?
    @State private var pending: [LAABrainSaveJournal.Pending] = []
    @State private var versions: [LAABrainSaveJournal.VersionSummary] = []
    @State private var busy = true
    @State private var recoveryUnavailable = false
    @State private var historyCorrupt = false
    @State private var historyUnreadable = false
    @State private var message: String?
    @State private var showHistory = false
    @State private var showFallbackWarning = false
    @State private var showHistoryWarning = false
    @State private var newlyCorruptHistory = false
    @State private var missingStageID: UUID?
    @State private var pendingToClear: LAABrainSaveJournal.Pending?
    @State private var showMissingStageAlert = false
    @State private var exportDocument: BrainRecoveryDocument?
    @State private var exportName = ""
    @State private var exportDigest = ""
    @State private var showExport = false
    @State private var canExportDraft = false
    #if DEBUG
    @State private var injectFixtureRace = ProcessInfo.processInfo.arguments.contains("-laa-brain-save-race-fixture")
    @State private var injectFixtureMissingStage = ProcessInfo.processInfo.arguments.contains("-laa-brain-save-missing-stage-fixture")
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if busy && snapshot == nil && pending.isEmpty {
                    ProgressView()
                } else if !pending.isEmpty {
                    interruptedView
                } else if let conflict {
                    conflictView(conflict)
                } else if snapshot != nil {
                    VStack {
                        if historyCorrupt {
                            Text(verbatim: "履歴が壊れています。該当する記録は退避しました。")
                                .foregroundStyle(LAAColor.attention)
                                .accessibilityIdentifier("laa.brain.history.corrupt")
                        }
                        if historyUnreadable {
                            Text(verbatim: "このアプリでは読めない形式の履歴があります。記録は残っています。")
                                .foregroundStyle(LAAColor.attention)
                        }
                        TextEditor(text: $draft)
                            .font(.body.monospaced()).disabled(busy)
                            .accessibilityIdentifier("laa.brain.edit.text")
                            .padding(.horizontal, LAASpacing.x2)
                        if canExportDraft {
                            Button("下書きを書き出す") { prepareExport(Data(draft.utf8), sourcePath: path) }
                        }
                    }
                } else {
                    ContentUnavailableView("Cannot open editor", systemImage: "exclamationmark.triangle", description: Text("Check folder access and try again."))
                }
            }
            .overlay(alignment: .bottom) {
                if let message {
                    Text(verbatim: message).font(.footnote).foregroundStyle(LAAColor.attention)
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
            }
            .navigationTitle(Text(verbatim: path.split(separator: "/").last.map(String.init) ?? path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { Task { await close() } }.disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("History") { showHistory = true }
                        .disabled(busy)
                        .accessibilityIdentifier("laa.brain.history")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(busy || recoveryUnavailable || snapshot == nil || conflict != nil || !pending.isEmpty)
                        .accessibilityIdentifier("laa.brain.edit.save")
                }
            }
        }
        .interactiveDismissDisabled()
        .task { await open() }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .data,
                      defaultFilename: exportName) { result in
            switch result {
            case .success(let url):
                let expected = exportDigest
                Task {
                    let matches = await Task.detached { LAABrainSaveCoordinator.verifyExport(url, digest: expected) }.value
                    message = matches ? "書き出した内容を確認しました。" : "書き出し先の内容を確認できませんでした。"
                }
            case .failure:
                message = "書き出せませんでした。元の記録は残っています。"
            }
        }
        .sheet(isPresented: $showHistory, onDismiss: { Task { await refreshHistory() } }) {
            BrainHistoryView(root: root, versions: versions, journal: coordinator.journal, didRestore: didSave,
                             canUse: snapshot != nil && pending.isEmpty && !recoveryUnavailable) { version in
                showHistory = false
                if let text = String(data: version.bytes, encoding: .utf8) {
                    Task { await resolve(using: text) }
                }
            }
        }
        .alert("Saved with limited protection", isPresented: $showFallbackWarning) {
            Button("OK") {
                if newlyCorruptHistory { showHistoryWarning = true } else { didSave(); dismiss() }
            }
        } message: {
            Text("This location cannot exchange files atomically. A change made immediately after the final check may not be retained.")
        }
        .alert("履歴が壊れています", isPresented: $showHistoryWarning) {
            Button("OK") { didSave(); dismiss() }
        } message: {
            Text(verbatim: "該当する記録は退避しました。ほかの履歴は残っています。")
        }
        .alert("Clear missing stage?", isPresented: $showMissingStageAlert) {
            Button("Clear pending", role: .destructive) {
                if let item = pendingToClear { Task { await clearMissing(item) } }
            }
            Button("Cancel", role: .cancel) { pendingToClear = nil }
        } message: {
            Text("The staged file is missing. A version may be unavailable; review History before clearing this record.")
        }
    }

    private var interruptedView: some View {
        List {
            Section {
                Text("An interrupted save needs review. The staged file may contain the original, a complete or partial draft, or a displaced version. Preserve it before editing again.")
                ForEach(pending) { item in
                    Button { Task { await preserve(item) } } label: {
                        Label("Preserve interrupted version", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("laa.brain.recovery.preserve")
                    Button("中断した版を書き出す") { Task { await exportPending(item) } }.disabled(busy)
                    if missingStageID == item.id {
                        Text("The staged file is missing. Its contents may not be recoverable.")
                            .foregroundStyle(LAAColor.attention)
                        Button("Clear missing stage") { pendingToClear = item; showMissingStageAlert = true }.disabled(busy)
                    }
                }
            }
            Section { Button("Review saved versions") { showHistory = true } }
        }
    }

    private func conflictView(_ conflict: BrainSaveConflict) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                Text(conflict.afterExchange
                     ? "Another version arrived during the exchange. Both versions were saved in History."
                     : "The note changed before saving. The note was not replaced; both versions are in History.")
                if let other = conflict.other {
                    versionPanel(conflict.afterExchange ? "Displaced version" : "Current note", text: other)
                } else {
                    Text("The displaced version is not UTF-8 text. Its original bytes remain in History.")
                }
                versionPanel("Your draft", text: conflict.draft)
                Button("Continue with my draft") { Task { await resolve(using: conflict.draft) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("laa.brain.conflict.useDraft")
                if let other = conflict.other {
                    Button("Continue with other version") { Task { await resolve(using: other) } }
                        .accessibilityIdentifier("laa.brain.conflict.useOther")
                }
                Text("Review the draft, then save it. The current note will be checked again.").font(.footnote)
            }.padding(LAASpacing.horizontal)
        }.disabled(busy).accessibilityIdentifier("laa.brain.conflict")
    }

    private func versionPanel(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: title).font(.headline)
            Text(verbatim: text).font(.body.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding().background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
    }

    @MainActor private func open() async {
        busy = true; message = nil
        recoveryUnavailable = true
        var readingNote = false
        do {
            let vault = LAABrainSaveJournal.vaultID(root)
            let (stored, unfinished) = try await Task.detached(priority: .userInitiated) {
                (try coordinator.journal.summaries(vault: vault, path: path),
                 try coordinator.journal.pending(vault: vault, path: path))
            }.value
            versions = stored; pending = unfinished
            if unfinished.isEmpty {
                readingNote = true
                let entry = try await Task.detached(priority: .userInitiated) {
                    try coordinator.begin(root: root, path: path)
                }.value
                readingNote = false
                snapshot = entry
                draft = String(decoding: entry.base, as: UTF8.self)
                versions = try await Task.detached(priority: .userInitiated) {
                    try coordinator.journal.summaries(vault: vault, path: path)
                }.value
            }
            historyCorrupt = try await Task.detached(priority: .userInitiated) {
                try coordinator.journal.corruptCount(vault: vault, path: path) > 0
            }.value
            historyUnreadable = try await Task.detached(priority: .userInitiated) {
                try coordinator.journal.unreadableCount(vault: vault, path: path) > 0
            }.value
            recoveryUnavailable = false
        } catch LAABrainSaveCoordinator.SaveError.historyUnavailable {
            message = "履歴を読めません。端末内の保存領域を確認してください。"
        } catch {
            message = readingNote ? "ノートを読めません。保管庫へのアクセスを確認してください。" : "履歴を読めません。端末内の保存領域を確認してください。"
        }
        busy = false
    }

    @MainActor private func save() async {
        guard let snapshot else { return }
        busy = true; message = nil
        let data = Data(draft.utf8)
        #if DEBUG
        let inject = injectFixtureRace
        injectFixtureRace = false
        let injectMissing = injectFixtureMissingStage
        injectFixtureMissingStage = false
        #endif
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                var worker = coordinator
                #if DEBUG
                if inject {
                    worker.fixtureAfterComparison = {
                        try Data("INTERVENING-FIXTURE".utf8).write(to: root.appendingPathComponent(path))
                    }
                }
                if injectMissing {
                    worker.fixtureBeforeStage = { throw LAABrainSaveCoordinator.SaveError.storage }
                }
                if ProcessInfo.processInfo.arguments.contains("-laa-brain-force-fallback-fixture") {
                    worker.fixtureForceFallback = true
                }
                #endif
                return try worker.save(root: root, snapshot: snapshot, draft: data)
            }.value
            versions = try await Task.detached(priority: .userInitiated) {
                try coordinator.journal.summaries(vault: snapshot.vault, path: path)
            }.value
            let foundCorruption = try await Task.detached(priority: .userInitiated) {
                try coordinator.journal.corruptCount(vault: snapshot.vault, path: path) > 0
            }.value
            newlyCorruptHistory = foundCorruption && !historyCorrupt
            historyCorrupt = foundCorruption
            switch outcome {
            case .saved(.exchange):
                if newlyCorruptHistory { showHistoryWarning = true } else { didSave(); dismiss() }
            case .saved(.checkedReplacement):
                showFallbackWarning = true
            case let .conflict(current, mine):
                conflict = BrainSaveConflict(other: String(data: current, encoding: .utf8),
                                             draft: String(decoding: mine, as: UTF8.self), afterExchange: false)
            case let .intervening(displaced, mine):
                conflict = BrainSaveConflict(other: String(data: displaced, encoding: .utf8),
                                             draft: String(decoding: mine, as: UTF8.self), afterExchange: true)
            }
        } catch {
            let saveError = error
            do {
                let (stored, unfinished) = try await Task.detached(priority: .userInitiated) {
                    (try coordinator.journal.summaries(vault: snapshot.vault, path: path),
                     try coordinator.journal.pending(vault: snapshot.vault, path: path))
                }.value
                versions = stored; pending = unfinished
                message = saveFailureMessage(saveError)
                if let value = saveError as? LAABrainSaveCoordinator.SaveError {
                    switch value {
                    case .recoveryExportRequired, .historyCapacity: canExportDraft = true
                    default: break
                    }
                }
            } catch {
                recoveryUnavailable = true
                message = "保存結果または履歴を確認できません。下書きを保持して保存領域を確認してください。"
            }
        }
        busy = false
    }

    @MainActor private func refreshHistory() async {
        let vault = LAABrainSaveJournal.vaultID(root)
        do {
            let (stored, corrupt, unreadable) = try await Task.detached(priority: .userInitiated) {
                (try coordinator.journal.summaries(vault: vault, path: path),
                 try coordinator.journal.corruptCount(vault: vault, path: path) > 0,
                 try coordinator.journal.unreadableCount(vault: vault, path: path) > 0)
            }.value
            versions = stored; historyCorrupt = corrupt; historyUnreadable = unreadable
        } catch { message = "履歴を読めません。端末内の保存領域を確認してください。" }
    }

    private func saveFailureMessage(_ error: Error) -> String {
        guard let error = error as? LAABrainSaveCoordinator.SaveError else {
            return "保存結果を確認できません。ノートと履歴を確認してください。"
        }
        switch error {
        case .conflictCopy: return "競合コピーは保存できません。ノートは変更していません。"
        case .tooLarge: return "ノートが大きすぎます。ノートは変更していません。"
        case .invalidText: return "テキストを保存できません。ノートは変更していません。"
        case .invalidPath: return "保存先を確認できません。ノートは変更していません。"
        case .pendingRecovery: return "中断した保存を確認してください。ノートは変更していません。"
        case .recoveryExportRequired: return "この保存先では安全に置換できません。ノートは変更していません。下書きを書き出してください。"
        case .durabilityUncertain: return "ノートは置換されましたが、保存の永続化を確認できません。履歴を確認してください。"
        case .historyCapacity: return "履歴の容量が上限です。ノートは変更していません。下書きを書き出してください。"
        case .recoveryPending: return "ノートは置換されました。退避版を履歴へ記録できなかったため、中断した版を保存するか書き出してください。"
        default: return "保存結果を確認できません。ノートと履歴を確認してください。"
        }
    }

    private func prepareExport(_ bytes: Data, sourcePath: String) {
        exportDocument = BrainRecoveryDocument(bytes: bytes)
        exportName = LAABrainSaveCoordinator.recoveryName(bytes: bytes, path: sourcePath)
        exportDigest = LAABrainSaveJournal.digest(bytes)
        showExport = true
    }

    @MainActor private func exportPending(_ item: LAABrainSaveJournal.Pending) async {
        busy = true
        do {
            let bytes = try await Task.detached { try coordinator.pendingBytes(item) }.value
            prepareExport(bytes, sourcePath: item.path)
        } catch { message = "中断した版を読み出せません。記録は消していません。" }
        busy = false
    }

    @MainActor private func resolve(using text: String) async {
        busy = true; message = nil
        do {
            let entry = try await Task.detached(priority: .userInitiated) {
                try coordinator.begin(root: root, path: path)
            }.value
            snapshot = entry; draft = text; conflict = nil
            versions = try await Task.detached(priority: .userInitiated) {
                try coordinator.journal.summaries(vault: entry.vault, path: path)
            }.value
        } catch { message = "The current note is unavailable. Your versions remain in History." }
        busy = false
    }

    @MainActor private func preserve(_ item: LAABrainSaveJournal.Pending) async {
        busy = true; message = nil
        do {
            _ = try await Task.detached(priority: .userInitiated) { try coordinator.preservePending(item) }.value
            await open()
        } catch LAABrainSaveCoordinator.SaveError.missingStage {
            missingStageID = item.id; busy = false
        } catch { message = "The interrupted version could not be preserved. It has not been removed."; busy = false }
    }

    @MainActor private func clearMissing(_ item: LAABrainSaveJournal.Pending) async {
        busy = true; pendingToClear = nil; message = nil
        do {
            try await Task.detached(priority: .userInitiated) { try coordinator.acknowledgeMissingStage(item) }.value
            missingStageID = nil
            await open()
        } catch { message = "The pending record could not be cleared."; busy = false }
    }

    @MainActor private func close() async {
        if let snapshot, Data(draft.utf8) != snapshot.base {
            busy = true
            let bytes = Data(draft.utf8)
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try coordinator.journal.record(vault: snapshot.vault, path: path, kind: .draft, bytes: bytes)
                }.value
            } catch {
                message = "Your draft could not be saved to History. Keep this screen open and check storage."
                busy = false
                return
            }
        }
        dismiss()
    }
}

private struct BrainHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let root: URL
    let versions: [LAABrainSaveJournal.VersionSummary]
    let journal: LAABrainSaveJournal
    let didRestore: () -> Void
    let canUse: Bool
    let use: (LAABrainSaveJournal.Version) -> Void

    var body: some View {
        NavigationStack {
            List {
                if versions.isEmpty { Text("No saved versions for this note.") }
                ForEach(versions) { version in
                    NavigationLink {
                        BrainHistoryDetail(root: root, summary: version, journal: journal, canUse: canUse,
                                           didRestore: didRestore, use: use)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(version.kind.label)
                            Text(version.created, style: .date).font(.caption)
                            Text(version.created, style: .time).font(.caption)
                        }
                    }.accessibilityIdentifier("laa.brain.history.version.\(version.kind.rawValue)")
                }
            }
            .navigationTitle("History")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }.accessibilityIdentifier("laa.brain.history.close")
            } }
        }
    }
}

private struct BrainHistoryDetail: View {
    let root: URL
    let summary: LAABrainSaveJournal.VersionSummary
    let journal: LAABrainSaveJournal
    let canUse: Bool
    let didRestore: () -> Void
    let use: ((LAABrainSaveJournal.Version) -> Void)?
    @State private var version: LAABrainSaveJournal.Version?
    @State private var failed = false
    @State private var restoring = false
    @State private var message: String?
    @State private var exportDocument: BrainRecoveryDocument?
    @State private var exportName = ""
    @State private var showExport = false

    var body: some View {
        ScrollView {
            if let version {
                VStack(alignment: .leading, spacing: LAASpacing.x3) {
                    if let text = String(data: version.bytes, encoding: .utf8) {
                        Text(verbatim: text).font(.body.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let use {
                            Button("Use as draft") { use(version) }
                                .buttonStyle(.borderedProminent).disabled(!canUse || restoring)
                                .accessibilityIdentifier("laa.brain.history.use")
                        }
                    } else {
                        Text("This version is not UTF-8 text. Restore its original bytes as a copy.")
                    }
                    Button("Restore copy in vault") { Task { await restoreCopy() } }
                        .disabled(restoring).accessibilityIdentifier("laa.brain.recovery.restore")
                    Button("Export copy to Files") {
                        exportDocument = BrainRecoveryDocument(bytes: version.bytes)
                        exportName = LAABrainSaveCoordinator.recoveryName(bytes: version.bytes, path: summary.path)
                        showExport = true
                    }.disabled(restoring).accessibilityIdentifier("laa.brain.recovery.export")
                    Text("Restoring creates a new file. For export, keep the suggested name to avoid replacing another note. The saved version stays in History.").font(.footnote)
                    if let message {
                        Text(verbatim: message).foregroundStyle(LAAColor.attention)
                            .accessibilityIdentifier("laa.brain.recovery.result")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            } else if failed {
                Text(verbatim: "履歴が壊れているか、記録を読めません。ほかの履歴を確認してください。").padding()
            } else {
                ProgressView().padding()
            }
        }
        .navigationTitle(summary.kind.label)
        .task {
            do { version = try await Task.detached(priority: .userInitiated) { try journal.version(summary) }.value }
            catch { failed = true }
        }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .data,
                      defaultFilename: exportName) { result in
            switch result {
            case .success(let url):
                restoring = true
                Task {
                    let verified = await Task.detached(priority: .userInitiated) {
                        LAABrainSaveCoordinator.verifyExport(url, digest: summary.digest)
                    }.value
                    message = verified ? "Exported copy verified." : "Export finished, but the copy could not be verified."
                    restoring = false
                    didRestore()
                }
            case .failure:
                message = "The copy could not be exported. The saved version remains in History."
            }
        }
    }

    @MainActor private func restoreCopy() async {
        restoring = true; message = nil
        #if DEBUG
        let forceExport = ProcessInfo.processInfo.arguments.contains("-laa-brain-history-force-export-fixture")
        #endif
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                var worker = LAABrainSaveCoordinator(journal: journal)
                #if DEBUG
                worker.fixtureForceRecoveryFallback = forceExport
                #endif
                return try worker.restoreCopy(root: root, summary: summary)
            }.value
            switch outcome {
            case .restored(let path): message = "Restored copy in vault root: \(path)"
            case .uncertain(let path): message = "A copy may exist at \(path), but could not be verified."
            }
            didRestore()
        } catch LAABrainSaveCoordinator.SaveError.recoveryExportRequired {
            message = "This location cannot create the copy directly. Use Export copy to Files."
        } catch {
            message = "The copy could not be restored. The saved version remains in History."
        }
        restoring = false
    }
}

private struct BrainRecoveryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}

/// This entry point lists saved paths from the journal, including paths that
/// no longer appear in the selected vault's index.
struct LAABrainRecoveryCatalogueView: View {
    @Environment(\.dismiss) private var dismiss
    let root: URL
    let didRestore: () -> Void
    private let journal = LAABrainSaveJournal()
    @State private var catalogue: LAABrainSaveJournal.Catalogue?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if let catalogue {
                    if catalogue.notes.isEmpty { Text("No saved versions for this folder.") }
                    ForEach(catalogue.notes) { note in
                        NavigationLink {
                            BrainRecoveryPathView(root: root, path: note.path, didRestore: didRestore)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: note.path)
                                if !note.pending.isEmpty { Text("Interrupted save").font(.caption).foregroundStyle(LAAColor.attention) }
                            }
                        }.accessibilityIdentifier("laa.brain.recovery.note")
                    }
                    if catalogue.unreadable > 0 {
                        Text("履歴が壊れているか一部を読めません。原本とほかの履歴は残っています。")
                            .foregroundStyle(LAAColor.attention)
                    }
                } else if failed {
                    Text("Recovery history is unavailable. Check storage and try again.")
                } else { ProgressView() }
            }
            .navigationTitle("Recovery history")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await refresh() }
            .refreshable { await refresh() }
        }
    }

    @MainActor private func refresh() async {
        do {
            catalogue = try await Task.detached(priority: .userInitiated) {
                try journal.catalogue(vault: LAABrainSaveJournal.vaultID(root))
            }.value
            failed = false
        } catch { failed = true }
    }
}

private struct BrainRecoveryPathView: View {
    let root: URL
    let path: String
    let didRestore: () -> Void
    private let coordinator = LAABrainSaveCoordinator()
    @State private var note: LAABrainSaveJournal.Catalogue.Note?
    @State private var busy = true
    @State private var message: String?
    @State private var missingID: UUID?
    @State private var pendingToClear: LAABrainSaveJournal.Pending?
    @State private var showClearAlert = false

    var body: some View {
        List {
            if let note {
                if !note.pending.isEmpty {
                    Section("Interrupted save") {
                        Text("The staged file may contain the original, a complete or partial draft, or a displaced version.")
                        ForEach(note.pending) { item in
                            Button("Preserve interrupted version") { Task { await preserve(item) } }
                                .disabled(busy).accessibilityIdentifier("laa.brain.recovery.preserve")
                            if missingID == item.id {
                                Text("The staged file is missing. Its contents may not be recoverable.")
                                    .foregroundStyle(LAAColor.attention)
                                Button("Clear missing stage") { pendingToClear = item; showClearAlert = true }.disabled(busy)
                            }
                        }
                    }
                }
                Section("Saved versions") {
                    if note.versions.isEmpty { Text("No readable saved versions.") }
                    ForEach(note.versions) { version in
                        NavigationLink {
                            BrainHistoryDetail(root: root, summary: version, journal: coordinator.journal,
                                               canUse: false, didRestore: didRestore, use: nil)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(version.kind.label)
                                Text(version.created, style: .date).font(.caption)
                                Text(version.created, style: .time).font(.caption)
                            }
                        }.accessibilityIdentifier("laa.brain.recovery.version.\(version.kind.rawValue)")
                    }
                }
            } else if busy { ProgressView() }
            if let message { Text(verbatim: message).foregroundStyle(LAAColor.attention) }
        }
        .navigationTitle(Text(verbatim: path))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .alert("Clear missing stage?", isPresented: $showClearAlert) {
            Button("Clear pending", role: .destructive) {
                if let item = pendingToClear { Task { await clearMissing(item) } }
            }
            Button("Cancel", role: .cancel) { pendingToClear = nil }
        } message: {
            Text("The staged file is missing. A version may be unavailable; review saved versions before clearing this record.")
        }
    }

    @MainActor private func refresh() async {
        busy = true
        do {
            let catalogue = try await Task.detached(priority: .userInitiated) {
                try coordinator.journal.catalogue(vault: LAABrainSaveJournal.vaultID(root))
            }.value
            note = catalogue.notes.first(where: { $0.path == path }) ?? LAABrainSaveJournal.Catalogue.Note(path: path)
            message = catalogue.unreadable > 0 ? "履歴が壊れているか一部を読めません。原本とほかの履歴は残っています。" : nil
        } catch { message = "Recovery history is unavailable. Check storage and try again." }
        busy = false
    }

    @MainActor private func preserve(_ item: LAABrainSaveJournal.Pending) async {
        busy = true; message = nil
        do {
            _ = try await Task.detached(priority: .userInitiated) { try coordinator.preservePending(item) }.value
            missingID = nil
            await refresh()
        } catch LAABrainSaveCoordinator.SaveError.missingStage {
            missingID = item.id; busy = false
        } catch { message = "The interrupted version could not be preserved. It has not been removed."; busy = false }
    }

    @MainActor private func clearMissing(_ item: LAABrainSaveJournal.Pending) async {
        busy = true; pendingToClear = nil
        do {
            try await Task.detached(priority: .userInitiated) { try coordinator.acknowledgeMissingStage(item) }.value
            missingID = nil
            await refresh()
        } catch { message = "The pending record could not be cleared."; busy = false }
    }
}

private extension LAABrainSaveJournal.Kind {
    var label: String {
        switch self {
        case .original: return "Original"
        case .draft: return "Draft"
        case .displaced: return "Displaced version"
        case .conflict: return "Conflicting version"
        case .interrupted: return "Interrupted version"
        }
    }
}
#endif
