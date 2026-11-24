#if LAA_BUILD
import Foundation

/// Hermes numbers raw events, including events this app does not render.
/// Keep the watermark on the wire side of the parser, before any side effects.
struct LAAChatEventReplay {
    /// Reconstruct UI, but don't re-trigger client-side tool actions.
    @TaskLocal static var isRecoveryDelivery = false

    struct Cursor: Equatable {
        let epoch: String
        let sequence: Int
    }

    var epoch: String? {
        didSet { if epoch != oldValue { sequences.removeAll() } }
    }
    private var sequences: [String: Int] = [:]

    func cursor(for sessionID: String) -> Cursor? {
        epoch.map { Cursor(epoch: $0, sequence: sequences[sessionID, default: 0]) }
    }

    mutating func admit(_ params: [String: AnyCodable]) -> Bool {
        guard let (id, seq) = Self.identity(params) else { return true }
        guard seq > sequences[id, default: 0] else { return false }
        sequences[id] = seq
        return true
    }

    /// `latest_seq` validates the complete prefix but is never a watermark.
    /// A concurrently emitted live frame may bridge the snapshot boundary;
    /// a hole that is still unfilled falls back to durable reconciliation.
    mutating func recover(
        sessionID: String, cursor: Cursor, result: [String: AnyCodable],
        buffered: [[String: AnyCodable]]
    ) -> [[String: AnyCodable]]? {
        guard epoch == cursor.epoch, result["epoch"]?.stringValue == cursor.epoch,
              result["truncated"]?.boolValue == false,
              let latest = result["latest_seq"]?.intValue, latest >= cursor.sequence,
              let events = result["events"]?.arrayValue else { return nil }
        var frames: [Int: [String: AnyCodable]] = [:]
        for value in events + buffered.map(AnyCodable.object) {
            guard let object = value.objectValue, let (id, seq) = Self.identity(object), id == sessionID else { return nil }
            if seq > cursor.sequence { frames[seq] = object }
        }
        let sequences = frames.keys.sorted()
        var expected = cursor.sequence
        for sequence in sequences {
            guard sequence - 1 == expected else { return nil }
            expected = sequence
        }
        guard expected >= latest else { return nil }
        self.sequences[sessionID] = cursor.sequence
        return sequences.compactMap { frames[$0] }
    }

    static func identity(_ params: [String: AnyCodable]) -> (String, Int)? {
        guard let id = params["session_id"]?.stringValue, !id.isEmpty,
              let seq = params["seq"]?.intValue, seq > 0 else { return nil }
        return (id, seq)
    }
}
#endif
