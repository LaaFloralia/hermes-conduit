//
//  LocalLiveProtocol.swift
//  Conduit
//
//  Wire format for Local Live: a live call through the user's own speech
//  server (Hugging Face speech-to-speech), relayed by the notifier's
//  `/local-live/socket`. The server speaks the OpenAI Realtime dialect Grok
//  Live's protocol already reads, so audio and server events go through
//  GrokLiveProtocol. What is Local Live's own: the session.update (no tools,
//  the server answers each turn by itself) and the turn frames the plugin
//  adds on the same socket. When the server asks its model address for an
//  answer, the plugin sends `conduit.turn`; Conduit runs it as a Hermes chat
//  turn and streams the reply back as `conduit.turn.delta`, then
//  `conduit.turn.done`.
//

import Foundation

enum LocalLiveProtocol {
    static let socketPath = SpeechServerSpeechStream.socketPath
    static let statusPath = SpeechServerSpeechStream.statusPath
    /// The OpenAI Realtime PCM rate, both ways. The 16 kHz microphone
    /// stream is upsampled to it, as for Grok Live.
    static let sampleRate: Double = 24_000
    /// The host's relay closes a socket that sends nothing for 60 s; a muted
    /// or paused call sends no audio, so a ping keeps it open.
    static let keepaliveInterval: Duration = .seconds(20)
    /// What one delta carries at most, in Unicode scalars (the plugin's
    /// Python counts code points, and takes up to 8,000 a frame).
    static let maximumDeltaCharacters = 4_000

    static var pluginMissingReason: String {
        AppLocalization.string("Update the Conduit plugin on your Hermes host to use Local Live.")
    }

    // MARK: Client → server

    /// Server turn detection that answers on its own (the server asks the
    /// plugin, which asks Conduit) and stops speaking when the user talks.
    /// No instructions or tools: the speech server's model is Hermes.
    static var sessionUpdate: [String: Any] {
        let format: [String: Any] = ["type": "audio/pcm", "rate": Int(sampleRate)]
        let turnDetection: [String: Any] = [
            "type": "server_vad",
            "create_response": true,
            "interrupt_response": true,
        ]
        let input: [String: Any] = ["format": format, "turn_detection": turnDetection]
        let output: [String: Any] = ["format": format]
        let session: [String: Any] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "audio": ["input": input, "output": output] as [String: Any],
        ]
        return ["type": "session.update", "session": session]
    }

    /// The plugin keeps every `conduit.` frame for itself; this one only
    /// resets the relay's idle timer.
    static let keepalive: [String: Any] = ["type": "conduit.ping"]

    static func turnDelta(turnID: String, text: String) -> [String: Any] {
        ["type": "conduit.turn.delta", "turn_id": turnID, "text": text]
    }

    static func turnDone(turnID: String) -> [String: Any] {
        ["type": "conduit.turn.done", "turn_id": turnID]
    }

    /// `text` in pieces the plugin takes whole.
    static func deltaChunks(_ text: String) -> [String] {
        let scalars = text.unicodeScalars
        guard scalars.count > maximumDeltaCharacters else { return text.isEmpty ? [] : [text] }
        var chunks: [String] = []
        var rest = Substring(text).unicodeScalars
        while !rest.isEmpty {
            chunks.append(String(rest.prefix(maximumDeltaCharacters)))
            rest = rest.dropFirst(maximumDeltaCharacters)
        }
        return chunks
    }

    // MARK: Server → client

    enum TurnFrame: Equatable {
        /// The speech server wants the reply to `text`.
        case turn(id: String, text: String)
        /// The server moved on (the user spoke again, or it gave up).
        case cancel(id: String)
    }

    /// The plugin's turn frame in `data`; nil for the speech server's own
    /// frames. Audio frames are checked without being parsed twice.
    static func turnFrame(_ data: Data) -> TurnFrame? {
        guard data.range(of: Data("\"conduit.turn".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let id = object["turn_id"] as? String, !id.isEmpty else { return nil }
        switch type {
        case "conduit.turn":
            return .turn(id: id, text: object["text"] as? String ?? "")
        case "conduit.turn.cancel":
            return .cancel(id: id)
        default:
            return nil
        }
    }

    static func encode(_ message: [String: Any]) throws -> String {
        try GrokLiveProtocol.encode(message)
    }
}
