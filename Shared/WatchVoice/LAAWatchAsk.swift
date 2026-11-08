//
//  LAAWatchAsk.swift
//  Conduit (LAA build)
//
//  LAA Voice on Apple Watch: the owner speaks to the Watch, the iPhone has
//  the LAA Bridge transcribe it (Haas, `voice:transcribe`) and sends the
//  words, unchanged, to an AI employee's chat as a message; the reply comes
//  back to the Watch. Nothing reshapes the words on the way (no polish):
//  only a leading employee name picks who gets them.
//
//  The audio goes as a file (WCSession.transferFile, 16 kHz mono PCM16
//  little-endian, at most `maxSeconds`), with `fileMetadata` naming the
//  request. Its state comes back as `.laaAskState`, pushed by the iPhone
//  and answered to the Watch's `.laaAskStatus` polls, so a push lost while
//  the Watch app was in the background is caught up.
//

#if LAA_BUILD
import Foundation

enum LAAWatchAsk {
    static let sampleRate = 16_000
    /// The Bridge's limit for one transcription.
    static let maxSeconds = 25
    static let maxAudioBytes = sampleRate * 2 * maxSeconds
    /// The longest a typed or dictated ask may be.
    static let maxTextLength = 2_000
    /// The metadata key a transferred audio file carries its request in.
    static let metadataKey = "laaAsk"

    /// What a transferred audio file is for.
    struct Request: Codable, Equatable {
        /// Chosen by the Watch: UUID string.
        var requestID: String
        /// A Hermes profile (`laa-…`). Nil: the employee named at the start
        /// of the words, else the first AI employee (LAAStaff case order).
        var profile: String?
        var sampleRate: Int = LAAWatchAsk.sampleRate
    }

    static func fileMetadata(_ request: Request) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(request) else { return [:] }
        return [metadataKey: data]
    }

    static func request(fromMetadata metadata: [String: Any]?) -> Request? {
        guard let data = metadata?[metadataKey] as? Data else { return nil }
        return try? JSONDecoder().decode(Request.self, from: data)
    }

    enum Phase: String, Codable, Equatable {
        /// The iPhone has the audio or text.
        case received
        case transcribing
        /// Sent to the employee; waiting for the reply.
        case sending
        /// `reply` is the employee's answer.
        case answered
        /// Sent; the employee was still working when the wait ran out. The
        /// answer will be in the chat on the iPhone.
        case stillWorking
        /// The employee asks a question or wants an approval in the chat.
        case needsInput
        /// The employee's chat was busy; the words wait or joined its reply.
        case queued
        /// Nothing was said.
        case silent
        /// `failure` says why, as the Watch shows it.
        case failed
        /// The iPhone has no request with this ID.
        case unknown

        var isFinal: Bool {
            switch self {
            case .received, .transcribing, .sending: return false
            case .answered, .stillWorking, .needsInput, .queued, .silent, .failed, .unknown: return true
            }
        }
    }

    struct State: Codable, Equatable {
        var requestID: String
        var phase: Phase
        /// The employee the words went (or go) to, once known.
        var profile: String?
        /// What the Bridge heard, unchanged.
        var transcript: String?
        var reply: String?
        var failure: String?
    }
}
#endif
