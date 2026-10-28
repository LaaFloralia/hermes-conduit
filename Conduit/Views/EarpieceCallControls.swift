//
//  EarpieceCallControls.swift
//  Conduit
//
//  "Hold calls to your ear" (VoiceEarpieceCalls): a voice conversation the
//  user starts plays from the earpiece like a phone call. The call screens'
//  Speaker button and the proximity sensor that turns the screen off
//  against the ear.
//

import SwiftUI
import UIKit

/// The call screen's Speaker button: moves a call the user started from
/// the earpiece to the loudspeaker and back. Draws nothing with the setting
/// off, or in a call from Hermes, whose Speaker button is CallKit's.
struct LiveVoiceCallSpeakerButton: View {
    @ObservedObject private var audio = VoiceAudioSessionCoordinator.shared
    @AppStorage(VoiceEarpieceCalls.preferenceKey) private var earpieceCalls = VoiceEarpieceCalls.defaultValue

    var body: some View {
        if earpieceCalls, !audio.isInNativeCall {
            let isOn = audio.conversationSpeakerChosen
            LiveVoiceCallButton(
                symbol: "speaker.wave.3.fill",
                title: AppLocalization.string("Speaker"),
                style: isOn ? .selected : .normal,
                action: { audio.setConversationSpeaker(!isOn) }
            )
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }
}

/// Turns the screen off against the ear while a call the user started runs
/// on this phone from the earpiece, as the Phone app does, and starts the
/// next call on the earpiece again once this one is over.
struct EarpieceCallProximity: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var audio = VoiceAudioSessionCoordinator.shared
    @AppStorage(VoiceEarpieceCalls.preferenceKey) private var earpieceCalls = VoiceEarpieceCalls.defaultValue

    private var monitorsProximity: Bool {
        VoiceEarpieceCalls.monitorsProximity(
            enabled: earpieceCalls,
            callOnPhone: appState.isVoiceInUse || appState.minimisedLiveVoice != nil,
            speakerChosen: audio.conversationSpeakerChosen,
            inNativeCall: audio.isInNativeCall
        )
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: monitorsProximity, initial: true) { _, monitors in
                UIDevice.current.isProximityMonitoringEnabled = monitors
            }
            .onChange(of: appState.isVoiceCallInProgress) { _, inProgress in
                if !inProgress { audio.conversationCallEnded() }
            }
            // Sign-out swaps the view out with a call possibly still up.
            .onDisappear {
                UIDevice.current.isProximityMonitoringEnabled = false
            }
    }
}
