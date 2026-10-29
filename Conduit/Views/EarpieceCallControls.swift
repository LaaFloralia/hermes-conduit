//
//  EarpieceCallControls.swift
//  Conduit
//
//  "Place calls as phone calls" (VoicePhoneCalls), where CallKit isn't
//  placing the call: a voice conversation the user starts plays from the
//  earpiece like a phone call. The call screens' own Speaker button and the
//  proximity sensor that turns the screen off against the ear. With CallKit
//  placing the call, iOS's call screen owns both.
//

import AVFAudio
import Combine
import SwiftUI
import UIKit

/// The call screen's Speaker button: moves a call the user started from
/// the earpiece to the loudspeaker and back. Draws nothing with the setting
/// off, or in a CallKit call, whose Speaker button is the system's: one from
/// Hermes, or one placed here.
struct LiveVoiceCallSpeakerButton: View {
    @ObservedObject private var audio = VoiceAudioSessionCoordinator.shared
    @AppStorage(VoicePhoneCalls.preferenceKey) private var phoneCalls = VoicePhoneCalls.defaultValue

    var body: some View {
        if phoneCalls, !audio.isInNativeCall {
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
    @AppStorage(VoicePhoneCalls.preferenceKey) private var phoneCalls = VoicePhoneCalls.defaultValue
    /// Headphones, Bluetooth or the car hold the audio: nothing to hold to
    /// the ear. Posted off the main thread, so read on it.
    @State private var playsElsewhere = false

    private static let routeChanges = NotificationCenter.default
        .publisher(for: AVAudioSession.routeChangeNotification)
        .receive(on: DispatchQueue.main)

    private var monitorsProximity: Bool {
        VoicePhoneCalls.monitorsProximity(
            enabled: phoneCalls,
            callOnPhone: appState.isVoiceInUse || appState.minimisedLiveVoice != nil,
            speakerChosen: audio.conversationSpeakerChosen,
            inNativeCall: audio.isInNativeCall,
            playsElsewhere: playsElsewhere
        )
    }

    private func readRoute() {
        playsElsewhere = VoicePhoneCalls.playsElsewhere(
            AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        )
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: monitorsProximity, initial: true) { _, monitors in
                UIDevice.current.isProximityMonitoringEnabled = monitors
            }
            .onChange(of: appState.isVoiceCallInProgress, initial: true) { _, inProgress in
                if inProgress { readRoute() } else { audio.conversationCallEnded() }
            }
            .onReceive(Self.routeChanges) { _ in readRoute() }
            // Sign-out swaps the view out with a call possibly still up, and
            // ends it without this view seeing the call end.
            .onDisappear {
                UIDevice.current.isProximityMonitoringEnabled = false
                audio.conversationCallEnded()
            }
    }
}
