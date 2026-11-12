#if LAA_BUILD
import Foundation

/// The model and effort a chat is actually running on, as Hermes reports
/// them for its live agent (`session.info`, a resume's snapshot,
/// `model.update`, a `/reasoning` change): never the profile's configured
/// values. Each value remembers the chat it was reported for, so a chat
/// just opened reads 「不明」 until Hermes answers for it instead of showing
/// the previous chat's (owner, 2026-11-12).
struct LAAChatRuntime: Equatable {
    private(set) var modelSessionID: String?
    private(set) var model: String?
    private(set) var provider: String?
    private(set) var effortSessionID: String?
    private(set) var effort: String?

    /// Takes what a report carried; a field it left out keeps its value.
    /// An empty value is a report that the chat has none to show.
    mutating func apply(sessionID: String?, model: String?, provider: String?, effort: String?) {
        guard let sessionID, !sessionID.isEmpty else { return }
        // Hermes reports the model with its provider; the provider only
        // picks the model's face, so it never stands without the model.
        if let model {
            modelSessionID = sessionID
            self.model = Self.value(model)
            self.provider = provider.flatMap(Self.value)
        }
        if let effort {
            effortSessionID = sessionID
            self.effort = Self.value(effort)
        }
    }

    struct Shown: Equatable {
        let model: String?
        let provider: String?
        let effort: String?
    }

    /// What the chip shows for the chat on screen; nil reads 「不明」.
    func shown(for sessionIDs: Set<String>) -> Shown {
        let modelKnown = modelSessionID.map(sessionIDs.contains) ?? false
        let effortKnown = effortSessionID.map(sessionIDs.contains) ?? false
        return Shown(model: modelKnown ? model : nil,
                     provider: modelKnown ? provider : nil,
                     effort: effortKnown ? effort : nil)
    }

    private static func value(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

import SwiftUI
import Combine

/// The chat composer's model · effort chip: Work's chip (LAAModelEffortChip),
/// display only. It listens to the two values it needs rather than the
/// whole AppState, so a streaming reply does not redraw the composer row.
struct LAAChatRuntimeChip: View {
    let appState: AppState
    @State private var runtime = LAAChatRuntime()
    @State private var activeSessionID: String?

    private var shown: LAAChatRuntime.Shown {
        runtime.shown(for: activeSessionID.map { [$0] } ?? [])
    }

    var body: some View {
        LAAModelEffortChip(model: shown.model, provider: shown.provider, effort: shown.effort)
            .accessibilityIdentifier("composer.runtime")
            .onReceive(appState.$laaChatRuntime.removeDuplicates()) { runtime = $0 }
            .onReceive(appState.$activeSessionId.removeDuplicates()) { activeSessionID = $0 }
    }
}
#endif
