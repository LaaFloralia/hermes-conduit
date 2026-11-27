#if LAA_BUILD
import Foundation

/// What the chaired-room (壁打ち) Voice bar shows. Pure: derived from the
/// real binding state (`LAAChairedVoiceBinding.core`), the room on screen
/// and the audio owner. Owns no audio and starts nothing.
enum LAAChairedVoiceSurfaceState: Equatable {
    /// Not a bound chaired room, another room's binding, or playback not wired.
    case hidden
    /// Bound and silent: only the explicit Voice button is offered.
    case off
    /// Engaged: members' settled lines are spoken; Talk and Stop offered.
    case listening
    /// The owner is talking (barge-in): new lines are held; Listen and Stop.
    case talking
    /// A staff call or native call owns audio: Voice is disabled and says why.
    case staffCallOwnsAudio

    static func make(
        roomID: String?,
        boundRoomID: String?,
        phase: LAAChairedVoicePlayback.Phase,
        owner: LAAChairedVoiceAudioOwner,
        playbackWired: Bool
    ) -> LAAChairedVoiceSurfaceState {
        guard playbackWired, let roomID, !roomID.isEmpty, boundRoomID == roomID else { return .hidden }
        if owner == .staffCall { return .staffCallOwnsAudio }
        switch phase {
        case .silent: return .off
        case .engaged: return .listening
        case .ownerTalking: return .talking
        }
    }
}

/// The bar's only outputs. Each closure maps 1:1 to one real
/// `LAAChairedVoiceBinding` call (patch 2); see `binding(...)`.
struct LAAChairedVoiceActions {
    /// Voice button → `binding.engage(generation:backlogThroughSeq:owner:)`.
    var engage: @MainActor () -> LAAChairedVoiceRefusal?
    /// Talk button → `binding.talk(generation:)`.
    var talk: @MainActor () -> Void
    /// Listen button (end of Talk) → `binding.talkEnded(generation:)`.
    var talkEnded: @MainActor () -> Void
    /// Stop button → `binding.stop(generation:)`.
    var stop: @MainActor () -> Void

    /// Previews and snapshots: touches nothing, so no mic, TTS or session.
    static let inert = LAAChairedVoiceActions(
        engage: { nil }, talk: {}, talkEnded: {}, stop: {})

    /// The production mapping. Every value is read at tap time from the
    /// single owner (AppState): `generation` = `groupRoomEpoch`,
    /// `backlogThroughSeq` = `activeRoomReplay.events.last?.seq`,
    /// `owner` = `chairedVoiceAudioOwner`. Nothing else is called.
    @MainActor
    static func binding(
        _ binding: LAAChairedVoiceBinding,
        generation: @escaping @MainActor () -> Int,
        backlogThroughSeq: @escaping @MainActor () -> Int?,
        owner: @escaping @MainActor () -> LAAChairedVoiceAudioOwner
    ) -> LAAChairedVoiceActions {
        LAAChairedVoiceActions(
            engage: { [weak binding] in
                guard let binding else { return .notBound }
                return binding.engage(generation: generation(), backlogThroughSeq: backlogThroughSeq(), owner: owner())
            },
            talk: { [weak binding] in binding?.talk(generation: generation()) },
            talkEnded: { [weak binding] in binding?.talkEnded(generation: generation()) },
            stop: { [weak binding] in binding?.stop(generation: generation()) }
        )
    }
}

/// Visible text and VoiceOver strings, kept here so tests read the same
/// words the bar draws.
enum LAAChairedVoiceCopy {
    static let voice = "Listen to Meeting"
    static let voiceHint = "押すと、これ以降の社員の発言を読み上げます。今までの発言は読み上げません。"
    static let talk = "Speak"
    static let talkHint = "読み上げを止めて、あなたが話す番にします。"
    static let listen = "Resume Listening"
    static let listenHint = "保留していた次の発言から読み上げを再開します。"
    static let stop = "Stop"
    static let stopHint = "読み上げを止め、音声を解放します。もう一度聞くまで無音です。"
    static let listening = "Speaking"
    static let talking = "Your Turn"
    static let staffCall = "社員との通話中は、会議の読み上げは使えません。"
    static let notBound = "この会議ではまだ読み上げを始められません。"

    static func refusal(_ refusal: LAAChairedVoiceRefusal) -> String {
        switch refusal {
        case .staffCallOwnsAudio: return staffCall
        case .notBound: return notBound
        }
    }
}

enum LAAChairedVoiceSurface {
    /// The iOS, Catalyst and synthetic-room gates passed. Visibility alone
    /// never activates audio; only explicit Talk can claim the endpoint.
    static let playbackWired = true
}
#endif
