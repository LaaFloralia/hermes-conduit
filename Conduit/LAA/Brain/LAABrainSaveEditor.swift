#if LAA_BUILD
import SwiftUI

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
    @State private var message: String?
    @State private var showHistory = false
    @State private var showFallbackWarning = false
    @State private var missingStageID: UUID?
    @State private var pendingToClear: LAABrainSaveJournal.Pending?
    @State private var showMissingStageAlert = false
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
                    TextEditor(text: $draft)
                        .font(.body.monospaced())
                        .disabled(busy)
                        .accessibilityIdentifier("laa.brain.edit.text")
                        .padding(.horizontal, LAASpacing.x2)
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
        .sheet(isPresented: $showHistory) {
            BrainHistoryView(versions: versions, journal: coordinator.journal,
                             canUse: snapshot != nil && pending.isEmpty && !recoveryUnavailable) { version in
                showHistory = false
                if let text = String(data: version.bytes, encoding: .utf8) {
                    Task { await resolve(using: text) }
                }
            }
        }
        .alert("Saved with limited protection", isPresented: $showFallbackWarning) {
            Button("OK") { didSave(); dismiss() }
        } message: {
            Text("This location cannot exchange files atomically. A change made immediately after the final check may not be retained.")
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
                Text("An interrupted save needs review. Preserve the staged file before editing again.")
                ForEach(pending) { item in
                    Button { Task { await preserve(item) } } label: {
                        Label("Preserve interrupted version", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("laa.brain.recovery.preserve")
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
        do {
            let vault = LAABrainSaveJournal.vaultID(root)
            let (stored, unfinished) = try await Task.detached(priority: .userInitiated) {
                (try coordinator.journal.summaries(vault: vault, path: path),
                 try coordinator.journal.pending(vault: vault, path: path))
            }.value
            versions = stored; pending = unfinished
            if unfinished.isEmpty {
                let entry = try await Task.detached(priority: .userInitiated) {
                    try coordinator.begin(root: root, path: path)
                }.value
                snapshot = entry
                draft = String(decoding: entry.base, as: UTF8.self)
                versions = try await Task.detached(priority: .userInitiated) {
                    try coordinator.journal.summaries(vault: vault, path: path)
                }.value
            }
            recoveryUnavailable = false
        } catch { message = "The note or its recovery history is unavailable." }
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
                #endif
                return try worker.save(root: root, snapshot: snapshot, draft: data)
            }.value
            versions = try await Task.detached(priority: .userInitiated) {
                try coordinator.journal.summaries(vault: snapshot.vault, path: path)
            }.value
            switch outcome {
            case .saved(.exchange):
                didSave(); dismiss()
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
            do {
                let (stored, unfinished) = try await Task.detached(priority: .userInitiated) {
                    (try coordinator.journal.summaries(vault: snapshot.vault, path: path),
                     try coordinator.journal.pending(vault: snapshot.vault, path: path))
                }.value
                versions = stored; pending = unfinished
                message = "The save result is uncertain. Review the note and History before trying again."
            } catch {
                recoveryUnavailable = true
                message = "The save result and recovery history are unavailable. Keep this draft and check storage."
            }
        }
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
    let versions: [LAABrainSaveJournal.VersionSummary]
    let journal: LAABrainSaveJournal
    let canUse: Bool
    let use: (LAABrainSaveJournal.Version) -> Void

    var body: some View {
        NavigationStack {
            List {
                if versions.isEmpty { Text("No saved versions for this note.") }
                ForEach(versions) { version in
                    NavigationLink {
                        BrainHistoryDetail(summary: version, journal: journal, canUse: canUse, use: use)
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
    let summary: LAABrainSaveJournal.VersionSummary
    let journal: LAABrainSaveJournal
    let canUse: Bool
    let use: (LAABrainSaveJournal.Version) -> Void
    @State private var version: LAABrainSaveJournal.Version?
    @State private var failed = false

    var body: some View {
        ScrollView {
            if let version, let text = String(data: version.bytes, encoding: .utf8) {
                Text(verbatim: text).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                Button("Use as draft") { use(version) }
                    .buttonStyle(.borderedProminent).disabled(!canUse)
                    .accessibilityIdentifier("laa.brain.history.use")
            } else if version != nil {
                Text("This version is not UTF-8 text.").padding()
            } else if failed {
                Text("This version could not be verified.").padding()
            } else {
                ProgressView().padding()
            }
        }
        .navigationTitle(summary.kind.label)
        .task {
            do { version = try await Task.detached(priority: .userInitiated) { try journal.version(summary) }.value }
            catch { failed = true }
        }
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
