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
    @State private var versions: [LAABrainSaveJournal.Version] = []
    @State private var busy = true
    @State private var message: String?
    @State private var showHistory = false
    @State private var showFallbackWarning = false
    #if DEBUG
    @State private var injectFixtureRace = ProcessInfo.processInfo.arguments.contains("-laa-brain-save-race-fixture")
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
                        .disabled(busy || snapshot == nil || conflict != nil || !pending.isEmpty)
                        .accessibilityIdentifier("laa.brain.edit.save")
                }
            }
        }
        .interactiveDismissDisabled()
        .task { await open() }
        .sheet(isPresented: $showHistory) {
            BrainHistoryView(versions: versions, canUse: snapshot != nil && pending.isEmpty) { version in
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
        do {
            let vault = LAABrainSaveJournal.vaultID(root)
            let stored = try coordinator.journal.versions(vault: vault, path: path)
            let unfinished = try coordinator.journal.pending(vault: vault, path: path)
            versions = stored; pending = unfinished
            if unfinished.isEmpty {
                let entry = try await Task.detached(priority: .userInitiated) {
                    try coordinator.begin(root: root, path: path)
                }.value
                snapshot = entry
                draft = String(decoding: entry.base, as: UTF8.self)
                versions = try coordinator.journal.versions(vault: vault, path: path)
            }
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
                #endif
                return try worker.save(root: root, snapshot: snapshot, draft: data)
            }.value
            versions = try coordinator.journal.versions(vault: snapshot.vault, path: path)
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
            pending = (try? coordinator.journal.pending(vault: snapshot.vault, path: path)) ?? []
            message = "Save could not be completed. Review History before trying again."
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
            versions = try coordinator.journal.versions(vault: entry.vault, path: path)
        } catch { message = "The current note is unavailable. Your versions remain in History." }
        busy = false
    }

    @MainActor private func preserve(_ item: LAABrainSaveJournal.Pending) async {
        busy = true; message = nil
        do {
            _ = try await Task.detached(priority: .userInitiated) { try coordinator.preservePending(item) }.value
            await open()
        } catch { message = "The interrupted version could not be preserved. It has not been removed."; busy = false }
    }

    @MainActor private func close() async {
        if let snapshot, Data(draft.utf8) != snapshot.base {
            do { try coordinator.journal.record(vault: snapshot.vault, path: path, kind: .draft, bytes: Data(draft.utf8)) }
            catch { message = "Your draft could not be saved to History. Keep this screen open and check storage."; return }
        }
        dismiss()
    }
}

private struct BrainHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let versions: [LAABrainSaveJournal.Version]
    let canUse: Bool
    let use: (LAABrainSaveJournal.Version) -> Void

    var body: some View {
        NavigationStack {
            List {
                if versions.isEmpty { Text("No saved versions for this note.") }
                ForEach(versions) { version in
                    NavigationLink {
                        ScrollView {
                            if let text = String(data: version.bytes, encoding: .utf8) {
                                Text(verbatim: text).font(.body.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                                Button("Use as draft") { use(version) }
                                    .buttonStyle(.borderedProminent).disabled(!canUse)
                                    .accessibilityIdentifier("laa.brain.history.use")
                            } else { Text("This version is not UTF-8 text.").padding() }
                        }
                        .navigationTitle(version.kind.label)
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
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
