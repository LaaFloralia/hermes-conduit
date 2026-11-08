//
//  ConduitWatchShortcuts.swift
//  Conduit Watch
//
//  Talk to Hermes in Siri and the Shortcuts app, so the Action button's
//  Shortcut option can start a call on watchOS before 26 too.
//

import AppIntents

struct ConduitWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        #if LAA_BUILD
        AppShortcut(
            intent: TalkToHermesIntent(),
            phrases: [
                "Talk to LAA in \(.applicationName)",
                "Start a \(.applicationName) call",
            ],
            shortTitle: "Talk to LAA",
            systemImageName: "waveform"
        )
        #else
        AppShortcut(
            intent: TalkToHermesIntent(),
            phrases: [
                "Talk to Hermes in \(.applicationName)",
                "Start a \(.applicationName) call",
            ],
            shortTitle: "Talk to Hermes",
            systemImageName: "waveform"
        )
        #endif
    }
}
