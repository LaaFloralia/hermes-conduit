#if LAA_BUILD
import Foundation

/// Who currently owns the device audio, as AppState reads it from real
/// state (`VoiceConversationController.state`, the coordinator's
/// `appliedPolicy == .conversation`, a native call). Chaired Voice never
/// takes audio from a staff call: it only speaks when this is `.none`.
enum LAAChairedVoiceAudioOwner: Equatable {
    case none
    /// A staff (employee) Voice Conversation or a native call holds audio.
    case staffCall
}

/// Why an explicit Voice action did not start meeting audio.
enum LAAChairedVoiceRefusal: Equatable {
    case staffCallOwnsAudio
    case notBound
}

/// Performs the core's effects (TTS, stop, lease release). Injected, so
/// the binding itself never touches audio; tests pass a recording fake.
@MainActor
protocol LAAChairedVoiceEffectHandling: AnyObject {
    func perform(_ effect: LAAChairedVoiceEffect, generation: Int)
}

/// Adapter from the real room log (`GroupEvent`) to the chaired Voice
/// core, plus the audio-ownership gate. Owns no audio and no timers.
@MainActor
final class LAAChairedVoiceBinding {
    private(set) var core = LAAChairedVoicePlayback()
    private weak var handler: LAAChairedVoiceEffectHandling?

    init(handler: LAAChairedVoiceEffectHandling? = nil) {
        self.handler = handler
    }

    func setHandler(_ handler: LAAChairedVoiceEffectHandling?) {
        self.handler = handler
    }

    /// A member message is final once a `turn.settled` names it by
    /// `message_event_id` — the rule `GroupRoomTurns.pendingResponder`
    /// uses. Everything else (user rows, turn bookkeeping, gateway/system
    /// rows, an unsettled member message) maps to a non-final or no line.
    nonisolated static func voiceEvents(_ events: [GroupEvent]) -> [LAAChairedVoiceEvent] {
        let committed = Set(events.compactMap { event -> String? in
            guard event.kind == "turn.settled" else { return nil }
            return event.payload["message_event_id"]?.stringValue
        })
        return events.filter(\.isMemberMessage).map { event in
            LAAChairedVoiceEvent(
                roomID: event.roomID, seq: event.seq, eventID: event.eventID,
                actorKind: event.actor.kind,
                speakerID: event.actor.profile ?? event.actor.id,
                text: event.messageText ?? "",
                isFinal: committed.contains(event.eventID)
            )
        }
    }

    // MARK: Room lifecycle (wired from AppState)

    func bind(roomID: String, generation: Int) {
        apply(core.bind(roomID: roomID, generation: generation), generation: generation)
    }

    func unbind(generation: Int) {
        apply(core.unbind(generation: generation), generation: generation)
    }

    /// The single owner (AppState) left the room surface or opened a room
    /// that is not chaired: tear down whatever generation is bound.
    func leaveRoom() {
        unbind(generation: core.generation)
    }

    /// Feed the whole current replay (initial tail, poll, resync). Re-feeding
    /// is safe: the core dedupes by event id and seq floor. While a staff
    /// call owns audio an engaged room stops instead of speaking.
    func ingest(_ events: [GroupEvent], generation: Int, owner: LAAChairedVoiceAudioOwner) {
        if owner != .none, core.phase != .silent {
            apply(core.stop(generation: generation), generation: generation)
        }
        var effects: [LAAChairedVoiceEffect] = []
        for event in Self.voiceEvents(events) {
            effects += core.receive(event, generation: generation)
        }
        apply(effects, generation: generation)
    }

    // MARK: Explicit owner actions

    /// The Voice button. Refused, with nothing started, while a staff call
    /// owns audio; never called from launch, scene phase or room open.
    @discardableResult
    func engage(generation: Int, backlogThroughSeq: Int?, owner: LAAChairedVoiceAudioOwner) -> LAAChairedVoiceRefusal? {
        guard core.roomID != nil, core.generation == generation else { return .notBound }
        guard owner == .none else { return .staffCallOwnsAudio }
        apply(core.engage(generation: generation, backlogThroughSeq: backlogThroughSeq), generation: generation)
        return nil
    }

    /// A staff call started (or the owner changed): meeting audio yields.
    func audioOwnerChanged(_ owner: LAAChairedVoiceAudioOwner, generation: Int) {
        guard owner != .none else { return }
        apply(core.stop(generation: generation), generation: generation)
    }

    func talk(generation: Int) { apply(core.talk(generation: generation), generation: generation) }
    func talkEnded(generation: Int) { apply(core.talkEnded(generation: generation), generation: generation) }
    func stop(generation: Int) { apply(core.stop(generation: generation), generation: generation) }

    /// The handler reports the end (or failure) of a line with the
    /// generation it was given; a stale one is ignored by the core.
    func completed(ticket: UInt64, generation: Int) {
        apply(core.completed(ticket: ticket, generation: generation), generation: generation)
    }

    private func apply(_ effects: [LAAChairedVoiceEffect], generation: Int) {
        guard let handler else { return }
        for effect in effects { handler.perform(effect, generation: generation) }
    }
}
#endif
