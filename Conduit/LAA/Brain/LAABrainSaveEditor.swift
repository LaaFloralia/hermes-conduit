#if LAA_BUILD
import SwiftUI
import UniformTypeIdentifiers

private struct BrainSaveConflict {
    let other: String?
    let draft: String
    let afterExchange: Bool
}

struct LAABrainSaveEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let root: URL
    let path: String
    let autoFocus: Bool
    let didSave: () -> Void
    private let coordinator = LAABrainSaveCoordinator()
    private let drafts = LAABrainDraftStore()
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

    init(root: URL, path: String, autoFocus: Bool = false, didSave: @escaping () -> Void) {
        self.root = root
        self.path = path
        self.autoFocus = autoFocus
        self.didSave = didSave
    }

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
                        LAAMarkdownEditor(text: draft, autoFocus: autoFocus, isEnabled: !busy) { changed in
                            draft = changed
                        }
                        if canExportDraft {
                            Button("下書きを書き出す") { prepareExport(Data(draft.utf8), sourcePath: path) }
                                .accessibilityIdentifier("laa.brain.edit.exportDraft")
                        }
                    }
                } else if canExportDraft {
                    ScrollView {
                        VStack(alignment: .leading, spacing: LAASpacing.x4) {
                            versionPanel("自分の下書き", text: draft)
                            Button("下書きを書き出す") { prepareExport(Data(draft.utf8), sourcePath: path) }
                                .accessibilityIdentifier("laa.brain.edit.exportDraft")
                        }.padding(LAASpacing.horizontal)
                    }
                } else {
                    ContentUnavailableView("編集画面を開けません", systemImage: "exclamationmark.triangle", description: Text("フォルダの接続を確認してください。"))
                }
            }
            .overlay(alignment: .bottom) {
                if let message {
                    // The message floats over the editor's own text, so it is
                    // reading-layer paper with a hairline, not glass.
                    Text(verbatim: message).font(.footnote).foregroundStyle(LAAColor.attention)
                        .padding()
                        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(LAAColor.separator, lineWidth: 1)
                        }
                        .padding()
                }
            }
            .navigationTitle(Text(verbatim: path.split(separator: "/").last.map(String.init) ?? path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LAACopy.close) { Task { await close() } }.disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("履歴") { showHistory = true }
                        .disabled(busy)
                        .accessibilityIdentifier("laa.brain.history")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LAACopy.save) { Task { await save() } }
                        .disabled(busy || recoveryUnavailable || snapshot == nil || conflict != nil || !pending.isEmpty)
                        .accessibilityIdentifier("laa.brain.edit.save")
                }
            }
        }
        .interactiveDismissDisabled()
        .task {
            await open()
        }
        .task(id: draft) {
            guard !busy, snapshot != nil else { return }
            do { try await Task.sleep(for: .milliseconds(400)); try Task.checkCancellation(); if !busy { preserveDraft() } }
            catch { }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { preserveDraft() } }
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
        .alert("履歴が壊れています", isPresented: $showHistoryWarning) {
            Button("OK") { didSave(); dismiss() }
        } message: {
            Text(verbatim: "該当する記録は退避しました。ほかの履歴は残っています。")
        }
        .alert("見つからないファイルの記録を消しますか？", isPresented: $showMissingStageAlert) {
            Button("記録を消す", role: .destructive) {
                if let item = pendingToClear { Task { await clearMissing(item) } }
            }.accessibilityIdentifier("laa.brain.recovery.confirmClearMissing")
            Button(LAACopy.cancel, role: .cancel) { pendingToClear = nil }
        } message: {
            Text("中断したファイルが見つかりません。記録を消す前に履歴を確認してください。")
        }
    }

    private var interruptedView: some View {
        List {
            Section {
                Text("中断した保存を確認してください。ファイルには原本、下書き、入れ替え時の内容が含まれている可能性があります。編集を再開する前に保存してください。")
                ForEach(pending) { item in
                    Button { Task { await preserve(item) } } label: {
                        Label("中断した内容を保存", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("laa.brain.recovery.preserve")
                    Button("中断した版を書き出す") { Task { await exportPending(item) } }.disabled(busy)
                    if missingStageID == item.id {
                        Text("中断したファイルが見つかりません。内容を復元できない可能性があります。")
                            .foregroundStyle(LAAColor.attention)
                            .accessibilityIdentifier("laa.brain.recovery.missingStage")
                        Button("見つからないファイルの記録を消す") { pendingToClear = item; showMissingStageAlert = true }.disabled(busy)
                            .accessibilityIdentifier("laa.brain.recovery.clearMissing")
                    }
                }
            }
            Section { Button("保存した履歴を確認") { showHistory = true }.accessibilityIdentifier("laa.brain.recovery.viewHistory") }
        }
    }

    private func conflictView(_ conflict: BrainSaveConflict) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                Text(conflict.afterExchange
                     ? AppLocalization.string("入れ替え中に別の変更がありました。両方の内容を履歴に保存しました。")
                     : AppLocalization.string("保存前にノートが変更されました。原本は上書きせず、両方の内容を履歴に保存しました。"))
                if let other = conflict.other {
                    versionPanel(conflict.afterExchange ? "入れ替え時の内容" : "現在のノート", text: other)
                } else {
                    Text("別の内容はUTF-8で読めません。元のデータは履歴に残っています。")
                }
                versionPanel("自分の下書き", text: conflict.draft)
                Button("自分の下書きで続ける") { Task { await resolve(using: conflict.draft) } }
                    .laaGlassButton(prominent: true)
                    .accessibilityIdentifier("laa.brain.conflict.useDraft")
                if let other = conflict.other {
                    Button("別の内容で続ける") { Task { await resolve(using: other) } }
                        .accessibilityIdentifier("laa.brain.conflict.useOther")
                }
                Text("下書きを確認して保存してください。現在のノートをもう一度確認します。").font(.footnote)
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
                let opening = try await Task.detached(priority: .userInitiated) {
                    try coordinator.openEditor(root: root, path: path, drafts: drafts)
                }.value
                readingNote = false
                switch opening {
                case let .note(entry, bytes, conflicted):
                    snapshot = entry
                    draft = String(decoding: bytes, as: UTF8.self)
                    if conflicted {
                        conflict = BrainSaveConflict(other: String(data: entry.base, encoding: .utf8), draft: draft, afterExchange: false)
                    }
                case let .detachedDraft(bytes):
                    snapshot = nil; draft = String(decoding: bytes, as: UTF8.self); canExportDraft = true
                    message = "ノートを読めません。保管庫へのアクセスを確認してください。"
                }
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
        if snapshot == nil, let retained = try? drafts.load(vault: LAABrainSaveJournal.vaultID(root), path: path) {
            draft = String(decoding: retained.bytes, as: UTF8.self); canExportDraft = true
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
            try drafts.save(.init(vault: snapshot.vault, path: path, base: snapshot.base, bytes: data))
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
            pending = try await Task.detached(priority: .userInitiated) {
                try coordinator.journal.pending(vault: snapshot.vault, path: path)
            }.value
            let foundCorruption = try await Task.detached(priority: .userInitiated) {
                try coordinator.journal.corruptCount(vault: snapshot.vault, path: path) > 0
            }.value
            newlyCorruptHistory = foundCorruption && !historyCorrupt
            historyCorrupt = foundCorruption
            switch outcome {
            case .saved(.exchange):
                try drafts.clear(vault: snapshot.vault, path: path)
                if newlyCorruptHistory { showHistoryWarning = true } else { didSave(); dismiss() }
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
        } catch { message = "現在のノートを読めません。内容は履歴に残っています。" }
        busy = false
    }

    @MainActor private func preserve(_ item: LAABrainSaveJournal.Pending) async {
        busy = true; message = nil
        do {
            _ = try await Task.detached(priority: .userInitiated) { try coordinator.preservePending(item) }.value
            await open()
        } catch LAABrainSaveCoordinator.SaveError.missingStage {
            missingStageID = item.id; busy = false
        } catch { message = "中断した内容を保存できませんでした。元の記録は残っています。"; busy = false }
    }

    @MainActor private func clearMissing(_ item: LAABrainSaveJournal.Pending) async {
        busy = true; pendingToClear = nil; message = nil
        do {
            try await Task.detached(priority: .userInitiated) { try coordinator.acknowledgeMissingStage(item) }.value
            missingStageID = nil
            await open()
        } catch { message = "中断した保存の記録を消せませんでした。"; busy = false }
    }

    @MainActor private func preserveDraft() {
        guard let snapshot else { return }
        do {
            if Data(draft.utf8) == snapshot.base { try drafts.clear(vault: snapshot.vault, path: path); return }
            try drafts.save(.init(vault: snapshot.vault, path: path, base: snapshot.base, bytes: Data(draft.utf8)))
        } catch { message = "下書きを端末に保管できません。画面を開いたまま保存領域を確認してください。" }
    }

    @MainActor private func close() async {
        preserveDraft()
        if let snapshot, Data(draft.utf8) != snapshot.base {
            busy = true
            let bytes = Data(draft.utf8)
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try coordinator.journal.record(vault: snapshot.vault, path: path, kind: .draft, bytes: bytes)
                }.value
            } catch {
                message = "下書きを履歴に保存できません。画面を開いたまま保存領域を確認してください。"
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
                if versions.isEmpty { Text("このノートに保存された履歴はありません。") }
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
            .navigationTitle("履歴")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(LAACopy.close) { dismiss() }.accessibilityIdentifier("laa.brain.history.close")
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
                            Button("下書きとして使う") { use(version) }
                                .laaGlassButton(prominent: true).disabled(!canUse || restoring)
                                .accessibilityIdentifier("laa.brain.history.use")
                        }
                    } else {
                        Text("この履歴はUTF-8で読めません。元のデータをコピーとして復元できます。")
                    }
                    Button("フォルダにコピーを復元") { Task { await restoreCopy() } }
                        .disabled(restoring).accessibilityIdentifier("laa.brain.recovery.restore")
                    Button("ファイルに書き出す") {
                        exportDocument = BrainRecoveryDocument(bytes: version.bytes)
                        exportName = LAABrainSaveCoordinator.recoveryName(bytes: version.bytes, path: summary.path)
                        showExport = true
                    }.disabled(restoring).accessibilityIdentifier("laa.brain.recovery.export")
                    Text("復元すると新しいファイルを作ります。書き出す場合は、ほかのノートを上書きしないよう提案された名前を使ってください。履歴は残ります。").font(.footnote)
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
                    message = verified ? "書き出した内容を確認しました。" : "書き出しましたが、内容を確認できませんでした。"
                    restoring = false
                    didRestore()
                }
            case .failure:
                message = "書き出せませんでした。履歴は残っています。"
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
            case .restored(let path): message = "フォルダ直下にコピーを復元しました: \(path)"
            case .uncertain(let path): message = "コピーが作られた可能性があります: \(path), ただし内容を確認できませんでした。"
            }
            didRestore()
        } catch LAABrainSaveCoordinator.SaveError.recoveryExportRequired {
            message = "この場所に直接復元できません。「ファイルに書き出す」を使ってください。"
        } catch {
            message = "復元できませんでした。履歴は残っています。"
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
                    if catalogue.notes.isEmpty { Text("このフォルダに保存された履歴はありません。") }
                    ForEach(catalogue.notes) { note in
                        NavigationLink {
                            BrainRecoveryPathView(root: root, path: note.path, didRestore: didRestore)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: note.path)
                                if !note.pending.isEmpty { Text("中断した保存").font(.caption).foregroundStyle(LAAColor.attention) }
                            }
                        }.accessibilityIdentifier("laa.brain.recovery.note")
                    }
                    if catalogue.unreadable > 0 {
                        Text("履歴が壊れているか一部を読めません。原本とほかの履歴は残っています。")
                            .foregroundStyle(LAAColor.attention)
                    }
                } else if failed {
                    Text("復元履歴を読めません。端末の保存領域を確認してください。")
                } else { ProgressView() }
            }
            .navigationTitle("復元履歴")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(LAACopy.close) { dismiss() } } }
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
                    Section("中断した保存") {
                        Text("中断したファイルには、元の内容、下書き、入れ替え時の内容のいずれかが含まれている可能性があります。")
                        ForEach(note.pending) { item in
                            Button("中断した内容を保存") { Task { await preserve(item) } }
                                .disabled(busy).accessibilityIdentifier("laa.brain.recovery.preserve")
                            if missingID == item.id {
                                Text("中断したファイルが見つかりません。内容を復元できない可能性があります。")
                                    .foregroundStyle(LAAColor.attention)
                                Button("見つからないファイルの記録を消す") { pendingToClear = item; showClearAlert = true }.disabled(busy)
                            }
                        }
                    }
                }
                Section("保存した履歴") {
                    if note.versions.isEmpty { Text("読める履歴はありません。") }
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
        .alert("見つからないファイルの記録を消しますか？", isPresented: $showClearAlert) {
            Button("記録を消す", role: .destructive) {
                if let item = pendingToClear { Task { await clearMissing(item) } }
            }
            Button(LAACopy.cancel, role: .cancel) { pendingToClear = nil }
        } message: {
            Text("中断したファイルが見つかりません。記録を消す前に履歴を確認してください。")
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
        } catch { message = "復元履歴を読めません。端末の保存領域を確認してください。" }
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
        } catch { message = "中断した内容を保存できませんでした。元の記録は残っています。"; busy = false }
    }

    @MainActor private func clearMissing(_ item: LAABrainSaveJournal.Pending) async {
        busy = true; pendingToClear = nil
        do {
            try await Task.detached(priority: .userInitiated) { try coordinator.acknowledgeMissingStage(item) }.value
            missingID = nil
            await refresh()
        } catch { message = "中断した保存の記録を消せませんでした。"; busy = false }
    }
}

private extension LAABrainSaveJournal.Kind {
    var label: String {
        switch self {
        case .original: return AppLocalization.string("編集開始時の内容")
        case .draft: return AppLocalization.string("下書き")
        case .displaced: return AppLocalization.string("入れ替え時の内容")
        case .conflict: return AppLocalization.string("競合した内容")
        case .interrupted: return AppLocalization.string("中断した内容")
        }
    }
}
#endif
