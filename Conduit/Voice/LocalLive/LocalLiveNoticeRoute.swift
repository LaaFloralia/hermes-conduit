//
//  LocalLiveNoticeRoute.swift
//  Conduit
//
//  A Local Live call has two shapes, and what a finished background job's
//  news is worth differs between them.
//

import Foundation

/// What a Local Live call does with a pending background-job notice.
///
/// An agent call (Live > Local) has the host's fast model on the front: a
/// job's result is news it hasn't heard, and the call says it as one of its
/// own turns, as Gemini, GPT and Grok Live do. A call that hands each
/// utterance to Hermes (`hermes_turns`) drops it instead: Hermes' reply is
/// already the call's own turn, so a notice would be said a second time.
enum LocalLiveNoticeHandling: Equatable {
    case deliverAsUpdate
    case drop

    static func forCall(runsAgentTurns: Bool) -> LocalLiveNoticeHandling {
        runsAgentTurns ? .deliverAsUpdate : .drop
    }
}
