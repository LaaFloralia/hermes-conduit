//
//  EarpieceCallControls.swift
//  Conduit
//
//  "Hold calls to your ear" (VoiceEarpieceCalls): a voice conversation the
//  user starts plays from the earpiece like a phone call. The call screens'
//  Speaker button and the proximity sensor that turns the screen off
//  against the ear.
//

import AVFAudio
import Combine
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
    /// Headphones, Bluetooth or the car hold the audio: nothing to hold to
    /// the ear. Posted off the main thread, so read on it.
    @State private var playsElsewhere = false

    private static let routeChanges = NotificationCenter.default
        .publisher(for: AVAudioSession.routeChangeNotification)
        .receive(on: DispatchQueue.main)

    private var monitorsProximity: Bool {
        VoiceEarpieceCalls.monitorsProximity(
            enabled: earpieceCalls,
            callOnPhone: appState.isVoiceInUse || appState.minimisedLiveVoice != nil,
            speakerChosen: audio.conversationSpeakerChosen,
            inNativeCall: audio.isInNativeCall,
            playsElsewhere: playsElsewhere
        )
    }

    private func readRoute() {
        playsElsewhere = VoiceEarpieceCalls.playsElsewhere(
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
