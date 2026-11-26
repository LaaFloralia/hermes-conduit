#if LAA_BUILD
import Foundation

/// One room-log event as chaired Voice sees it: sanitized, already decoded
/// from `GroupEvent`, no AnyCodable. `isFinal` is true only for a posted
/// member message (`message.member`); streaming previews and turn/activity
/// rows come in with `isFinal == false` and are never spoken.
struct LAAChairedVoiceEvent: Equatable {
    let roomID: String
    let seq: Int
    let eventID: String
    /// `GroupActor.kind`: only `member` (staff, the chair included) speaks.
    let actorKind: String
    let speakerID: String
    let text: String
    let isFinal: Bool
}

/// A staff line waiting for, or in, playback.
struct LAAChairedVoiceUtterance: Equatable {
    let roomID: String
    let seq: Int
    let eventID: String
    let speakerID: String
    let text: String
}

/// What the integration must do. Effects are the only output; the core
/// itself never touches audio, the session coordinator or the network.
enum LAAChairedVoiceEffect: Equatable {
    /// Speak this line; report its end with `completed(ticket:)`.
    case speak(LAAChairedVoiceUtterance, ticket: UInt64)
    /// Stop the line holding this ticket now (its late completion is ignored).
    case stopSpeaking(ticket: UInt64)
    /// Nothing is left to say: release the playback audio lease.
    case releaseAudio
}

/// Deterministic serial playback and barge-in for a chaired room (壁打ち).
///
/// - One line at a time, in room-log `seq` order; a line is spoken at most
///   once (event id), whether it arrives live, by replay or both.
/// - Silent until engaged: launch, observer attach and the backlog present
///   at `engage` only advance bookkeeping.
/// - Talk (barge-in) and Stop flush the queue, stop the current line and
///   invalidate its ticket; Stop also disengages.
/// - Room-generation ownership: every call carries the owner's room
///   generation. A different room or an older generation is ignored, so a
///   previous room's teardown or late events never touch the current one.
struct LAAChairedVoicePlayback {
    enum Phase: Equatable {
        /// Not engaged: events are recorded as heard, nothing is spoken.
        case silent
        /// Engaged and free to speak.
        case engaged
        /// The owner is talking (barge-in): new lines wait for `talkEnded`.
        case ownerTalking
    }

    private(set) var phase: Phase = .silent
    private(set) var roomID: String?
    private(set) var generation: Int = 0
    private(set) var queue: [LAAChairedVoiceUtterance] = []
    private(set) var current: (utterance: LAAChairedVoiceUtterance, ticket: UInt64)?
    /// Backlog present at engage (and everything flushed) stays unspoken.
    private(set) var silentThroughSeq = Int.min
    private(set) var muted = false
    private var heardSeqs: Set<Int> = []
    private var heardEventIDs: Set<String> = []
    private var heardOrder: [(id: String, seq: Int)] = []
    private var nextTicket: UInt64 = 0
    private var hasBound = false
    private var highestSeq = Int.min

    /// Bound on remembered event ids; older ids fall back to the seq floor.
    static let heardLimit = 512

    /// Takes the room for a new owner generation (open room, switch room,
    /// reattach). A newer generation replaces everything, silently; the same
    /// generation re-binding the same room is a no-op; an older one is
    /// ignored, even after `unbind`.
    @discardableResult
    mutating func bind(roomID: String, generation: Int) -> [LAAChairedVoiceEffect] {
        if self.roomID == roomID, generation == self.generation { return [] }
        guard !hasBound || generation > self.generation else { return [] }
        hasBound = true
        let effects = flush(releasing: current != nil || !queue.isEmpty)
        self.roomID = roomID
        self.generation = generation
        phase = .silent
        silentThroughSeq = Int.min
        muted = false
        heardEventIDs = []
        heardSeqs = []
        heardOrder = []
        highestSeq = Int.min
        return effects
    }

    /// The owner turned Voice on in the room. Everything already received
    /// (`backlogThroughSeq`, or the highest seq seen) stays silent.
    @discardableResult
    mutating func engage(generation: Int, backlogThroughSeq: Int? = nil) -> [LAAChairedVoiceEffect] {
        guard owns(generation), phase == .silent else { return [] }
        silentThroughSeq = max(silentThroughSeq, highestSeq, backlogThroughSeq ?? Int.min)
        phase = .engaged
        return []
    }

    @discardableResult
    mutating func receive(_ event: LAAChairedVoiceEvent, generation: Int) -> [LAAChairedVoiceEffect] {
        guard owns(generation), event.roomID == roomID else { return [] }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard event.isFinal, event.actorKind == "member", !text.isEmpty else { return [] }
        guard !event.eventID.isEmpty, !heardEventIDs.contains(event.eventID), !heardSeqs.contains(event.seq),
              event.seq > silentThroughSeq else { return [] }
        highestSeq = max(highestSeq, event.seq)
        remember(event.eventID, seq: event.seq)
        guard phase != .silent, !muted else { return [] }
        let line = LAAChairedVoiceUtterance(
            roomID: event.roomID, seq: event.seq, eventID: event.eventID,
            speakerID: event.speakerID, text: text
        )
        let index = queue.firstIndex { $0.seq > line.seq } ?? queue.endIndex
        queue.insert(line, at: index)
        return startNextIfIdle()
    }

    /// The speaker finished (or failed) the line holding `ticket`. A stale
    /// ticket — stopped, flushed, or from an older generation — is ignored.
    @discardableResult
    mutating func completed(ticket: UInt64, generation: Int) -> [LAAChairedVoiceEffect] {
        guard owns(generation), let current, current.ticket == ticket else { return [] }
        self.current = nil
        let next = startNextIfIdle()
        return next.isEmpty ? [.releaseAudio] : next
    }

    /// Barge-in: the owner pressed Talk.
    @discardableResult
    mutating func talk(generation: Int) -> [LAAChairedVoiceEffect] {
        guard owns(generation), phase != .silent else { return [] }
        let effects = flush(releasing: current != nil || !queue.isEmpty)
        phase = .ownerTalking
        return effects
    }

    /// The owner's Talk ended (sent or cancelled): lines received since play.
    @discardableResult
    mutating func talkEnded(generation: Int) -> [LAAChairedVoiceEffect] {
        guard owns(generation), phase == .ownerTalking else { return [] }
        phase = .engaged
        return startNextIfIdle()
    }

    mutating func flushRound(generation: Int) -> [LAAChairedVoiceEffect] {
        guard owns(generation), phase == .engaged else { return [] }
        return flush(releasing: current != nil || !queue.isEmpty)
    }

    mutating func skip(generation: Int) -> [LAAChairedVoiceEffect] {
        guard owns(generation), let current else { return [] }
        return [.stopSpeaking(ticket: current.ticket)] + completed(ticket: current.ticket, generation: generation)
    }

    mutating func toggleMute(generation: Int) -> [LAAChairedVoiceEffect] {
        guard owns(generation), phase != .silent else { return [] }
        muted.toggle()
        return muted ? flush(releasing: current != nil || !queue.isEmpty) : []
    }

    /// Stop: flush, stop and disengage. Voice stays silent until `engage`.
    @discardableResult
    mutating func stop(generation: Int) -> [LAAChairedVoiceEffect] {
        guard owns(generation) else { return [] }
        let effects = flush(releasing: current != nil || !queue.isEmpty)
        phase = .silent
        muted = false
        return effects
    }

    /// The owner of `generation` left the room. Only the current owner
    /// tears down; an older generation's late teardown is a no-op.
    @discardableResult
    mutating func unbind(generation: Int) -> [LAAChairedVoiceEffect] {
        guard owns(generation) else { return [] }
        let effects = flush(releasing: current != nil || !queue.isEmpty)
        roomID = nil
        phase = .silent
        return effects
    }

    // MARK: - Private

    private func owns(_ generation: Int) -> Bool {
        roomID != nil && generation == self.generation
    }

    private mutating func remember(_ eventID: String, seq: Int) {
        heardEventIDs.insert(eventID)
        heardSeqs.insert(seq)
        heardOrder.append((eventID, seq))
        if heardOrder.count > Self.heardLimit {
            let dropped = heardOrder.removeFirst()
            heardEventIDs.remove(dropped.id)
            heardSeqs.remove(dropped.seq)
            silentThroughSeq = max(silentThroughSeq, dropped.seq)
        }
    }

    private mutating func flush(releasing: Bool) -> [LAAChairedVoiceEffect] {
        var effects: [LAAChairedVoiceEffect] = []
        if let current { effects.append(.stopSpeaking(ticket: current.ticket)) }
        current = nil
        queue.removeAll()
        // Everything heard so far stays unspoken, including ids that fell
        // out of the bounded set.
        silentThroughSeq = max(silentThroughSeq, highestSeq)
        if releasing { effects.append(.releaseAudio) }
        return effects
    }

    private mutating func startNextIfIdle() -> [LAAChairedVoiceEffect] {
        guard phase == .engaged, current == nil, !queue.isEmpty else { return [] }
        let line = queue.removeFirst()
        nextTicket &+= 1
        current = (line, nextTicket)
        return [.speak(line, ticket: nextTicket)]
    }
}
#endif
