#if LAA_BUILD
import Foundation

/// Conversation phase only; the existing playback core is the serial queue.
/// The room remains the only durable transcript, including anything not spoken.
struct LAAMeetingTurn: Equatable {
    enum Phase: Equatable {
        case idle, listening, sending, waiting, speaking(index: Int, total: Int)
    }

    enum Event {
        case join, leave, vadEnd, tapTalk, sendRegistered, sendDeclined
        case messageComplete(total: Int), ttsFinished(remaining: Int), bargeIn, roundClosed, timeout
    }

    private(set) var phase: Phase = .idle
    private(set) var ownerTalking = false
    private var spoken = 0

    mutating func apply(_ event: Event) {
        if case .leave = event { self = Self(); return }
        if phase == .idle {
            if case .join = event { phase = .listening }
            return
        }
        switch event {
        case .join, .leave: break
        case .tapTalk, .bargeIn:
            spoken = 0
            ownerTalking = true
            phase = .listening
        case .vadEnd:
            guard ownerTalking else { return }
            ownerTalking = false
            phase = .sending // Editable draft; never auto-send.
        case .sendRegistered:
            ownerTalking = false
            spoken = 0
            phase = .waiting
        case .sendDeclined:
            if case .sending = phase { phase = .listening }
        case .messageComplete(let total):
            guard !ownerTalking, total > 0 else { return }
            phase = .speaking(index: spoken + 1, total: spoken + total)
        case .ttsFinished(let remaining):
            guard case .speaking = phase else { return }
            spoken += 1
            phase = remaining > 0 ? .speaking(index: spoken + 1, total: spoken + remaining) : .waiting
        case .roundClosed, .timeout:
            guard !ownerTalking else { return }
            if case .sending = phase { return } // Do not hide an editable draft.
            spoken = 0
            phase = .listening
        }
    }

    /// Limit audio independently of the room prompt. Full text stays in the
    /// transcript. Named mentions/Markdown are handled by the speech filter.
    static func spokenExcerpt(_ text: String) -> String {
        let spoken = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("詳細:") && !trimmed.hasPrefix("詳細：")
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var sentences = 0
        var end = spoken.startIndex
        for character in spoken.prefix(240) {
            end = spoken.index(after: end)
            if "。！？!?".contains(character) || character == "." && (end == spoken.endIndex || spoken[end].isWhitespace) {
                sentences += 1
                if sentences == 2 { break }
            }
        }
        return String(spoken[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
/// Ends an explicitly opened iPhone capture after speech, never pre-opens
/// the microphone and never sends a message. Durations are monotonic.
struct LAAMeetingVAD {
    private var loudSince: Duration?
    private var quietSince: Duration?
    private var heardSpeech = false
    private var ended = false

    mutating func observe(level: Double, at elapsed: Duration) -> Bool {
        guard level.isFinite, !ended else { return false }
        if level >= 0.024 {
            let start = loudSince ?? elapsed
            loudSince = start
            heardSpeech = heardSpeech || elapsed - start >= .milliseconds(140)
            quietSince = nil
        } else if level < 0.016 {
            loudSince = nil
            if heardSpeech {
                let start = quietSince ?? elapsed
                quietSince = start
                if elapsed - start >= .milliseconds(1_200) { ended = true; return true }
            }
        } else {
            loudSince = nil
            quietSince = nil
        }
        return false
    }
}
#endif
