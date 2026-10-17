//
//  LocalLiveViews.swift
//  Conduit
//
//  Local Live voice mode: its Voice settings section. The call itself
//  shares Gemini Live's sheet (GeminiLiveVoiceSheet).
//

import SwiftUI

/// What Voice settings needs to show the Local Live option.
struct LocalLiveSettingsModel {
    var enabled: Bool
    var setEnabled: (Bool) -> Void
}

/// Local Live's setup: the speech server Hermes connects to, and the model
/// address the server asks for each reply.
struct LocalLiveSettingsSection: View {
    @ObservedObject var service: HermesVoiceConfigurationService

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Local Live"), symbol: "server.rack", tint: .conduitAccent) {
            Text(AppLocalization.string("Talk with Hermes through a speech server you run, such as Hugging Face speech-to-speech. The server listens and speaks in its own voice; what you say goes to Hermes as a turn in the call's chat, and Hermes' reply is spoken as it is written. Turning this on turns Gemini Live, GPT-Live and Grok Live off."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(AppLocalization.string("1. Your speech server"))
                .font(.subheadline.weight(.semibold))
            SpeechServerSettingsView(service: service)
            Text(AppLocalization.string("2. Point the server at Hermes"))
                .font(.subheadline.weight(.semibold))
            SpeechServerVoiceSettingsView(service: service, showsIntro: false)
        }
    }
}
