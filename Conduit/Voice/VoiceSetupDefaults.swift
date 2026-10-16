//
//  VoiceSetupDefaults.swift
//  Conduit
//
//  The one-switch happy path for classic Voice. Turning Voice on picks
//  defaults that work on any Hermes host without installing anything:
//  speech to text on this iPhone (Apple's on-device model), and replies
//  spoken with this iPhone's voice unless the profile has its own Hermes
//  voice (`VoiceSpeechOutput.resolved`). A reviewer whose Voice was never
//  set up read CarPlay's "Voice unavailable" as CarPlay not working; with
//  these defaults the switch alone is enough.
//

import Foundation

enum VoiceSetupDefaults {
    /// Hermes' provider id for Microsoft Edge TTS.
    static let edgeTTSProviderID = "edge"

    struct Plan: Equatable {
        /// Choose "On this iPhone" for speech to text.
        var usesOnDeviceTranscription = false
    }

    /// What turning Voice on should change. Only fills in what is missing:
    /// a speech-to-text choice the user already made is kept. The
    /// assistant voice needs nothing: this iPhone speaks unless the profile
    /// has its own Hermes voice.
    static func plan(
        transcriptionModeChosen: Bool,
        appleSpeechAvailability: AppleSpeechRecognitionAvailability,
        snapshot: VoiceConfigurationSnapshot
    ) -> Plan {
        Plan(usesOnDeviceTranscription: !transcriptionModeChosen && appleSpeechAvailability.canAttemptRecognition)
    }

    enum Readiness: Equatable {
        case ready
        /// Hermes reported a status other than ready ("needs_keys"…).
        case notReady(status: String)
        /// Hermes reported nothing for this provider.
        case unknown
    }

    /// Hermes' own readiness report for one provider, whether or not it is
    /// the selected one.
    static func providerReadiness(_ id: String, in providers: [VoiceProviderConfiguration]) -> Readiness {
        guard let readiness = providers.first(where: { $0.descriptor.id == id })?.readiness else { return .unknown }
        if readiness.status.caseInsensitiveCompare("ready") == .orderedSame { return .ready }
        return .notReady(status: readiness.status)
    }
}
