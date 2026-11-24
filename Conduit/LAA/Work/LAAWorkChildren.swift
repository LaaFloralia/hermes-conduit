#if LAA_BUILD
import Foundation

/// A Work Session's children (sessions whose `parentId` is this one) for the
/// working pill and the inline subagent cards: one card per spawn batch, set
/// in the transcript after the message it followed.
enum LAAWorkChildren {
    /// Children started within this many seconds of one another are one batch.
    static let batchWindow: TimeInterval = 120

    static func child(_ session: LAAWorkSession, options: LAAWorkSessionOptions?) -> LAAWorkingChild {
        let state: LAAWorkingChild.State
        switch session.phase {
        case "running": state = .running
        case "created", "awaiting_review": state = .waiting
        case "awaiting_decision", "stop_unconfirmed": state = .attention
        case "error": state = .failed
        default: state = .done
        }
        let asked = LAAWorkSessionStyle.asked(session)
        let model = LAAWorkSessionStyle.appliedModel(session, options: options)
            ?? [LAAWorkSessionStyle.modelName(asked.model, provider: session.requested?.provider, options: options),
                LAAWorkSessionStyle.effort(asked.effort)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return LAAWorkingChild(
            id: session.id,
            title: session.name,
            state: state,
            meta: model.isEmpty ? nil : model,
            preview: nil,
            startedAt: state == .running ? date(session.createdAt) : nil,
            resolvable: true,
            label: LAAWorkPresentation.phase(session.phase)
        )
    }

    /// Children in spawn order, cut where more than `batchWindow` passed.
    static func batches(_ children: [LAAWorkSession]) -> [[LAAWorkSession]] {
        let ordered = children.sorted { lhs, rhs in
            interval(lhs.createdAt) < interval(rhs.createdAt)
        }
        var result: [[LAAWorkSession]] = []
        for child in ordered {
            if let previous = result.last?.last,
               interval(child.createdAt) - interval(previous.createdAt) <= batchWindow {
                result[result.count - 1].append(child)
            } else {
                result.append([child])
            }
        }
        return result
    }

    /// Where each batch sits: after the last message sent before it started
    /// (`nil`: before the first message shown).
    struct Placement: Equatable {
        let afterMessageID: String?
        let children: [LAAWorkSession]
        var id: String { children.first?.id ?? "" }
    }

    static func placements(_ children: [LAAWorkSession], messages: [LAAWorkConversationMessage]) -> [Placement] {
        batches(children).map { batch in
            let start = interval(batch.first?.createdAt)
            let anchor = messages.last { message in
                guard let stamp = message.timestamp else { return false }
                return interval(stamp) <= start
            }
            // With no times to read, the batch closes the transcript.
            let timed = messages.contains { $0.timestamp != nil }
            return Placement(afterMessageID: timed ? anchor?.id : messages.last?.id, children: batch)
        }
    }

    /// The running turn's start: the owner's last message.
    static func turnStart(_ messages: [LAAWorkConversationMessage]) -> Date? {
        messages.last { $0.role == "user" }.flatMap { $0.timestamp }.flatMap(date)
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return MessageTimestampFormatter.date(from: raw)
    }

    private static func interval(_ raw: String?) -> TimeInterval {
        date(raw)?.timeIntervalSinceReferenceDate ?? 0
    }
}
#endif
