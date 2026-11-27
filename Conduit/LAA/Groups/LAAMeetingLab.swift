#if LAA_BUILD
import Foundation

@MainActor
private enum LAAMeetingLabMode {
    static var enabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let process = ProcessInfo.processInfo
        return process.environment["CONDUIT_UITEST"] == "1"
            && process.arguments.contains("-LAA_MEETING_FIXTURE")
        #else
        return false
        #endif
    }
}

@MainActor
enum LAAMeetingLab {
    static var isEnabled: Bool { LAAMeetingLabMode.enabled }

    #if DEBUG && targetEnvironment(simulator)
    static let roomID = "meeting-fixture"
    static let members = [("laa-monet", "Monet"), ("laa-cto", "設計担当"), ("laa-cos", "進行担当")].map { id, name in
        GroupMember(memberID: id, profile: id, handle: id, displayName: name, target: nil, extra: [:])
    }
    static let room = GroupRoom(roomID: roomID, name: "Voice", members: members, authorityGatewayID: "fixture",
                                authorityEpoch: 1, revision: 1, createdAt: 0, updatedAt: 0, disbandedAt: nil, latestSeq: 3)

    static func user(seq: Int, text: String) -> GroupEvent {
        event(seq: seq, kind: "message.user", id: "u\(seq)", payload: ["text": .string(text)])
    }

    static func settled(seq: Int, text: String, roundID: String = "historical") -> [GroupEvent] {
        let id = "m\(seq)"
        let round: AnyCodable = .string(roundID)
        return [event(seq: seq, kind: "message.member", id: id, payload: ["text": .string(text)]),
                event(seq: seq + 1, kind: "turn.settled", id: "s\(seq)", payload: ["message_event_id": .string(id), "discussion_event_id": round]),
                event(seq: seq + 2, kind: "room.activity", id: "closed\(seq)", payload: ["status": .string("settled"), "discussion_event_id": round])]
    }

    private static func event(seq: Int, kind: String, id: String, payload: [String: AnyCodable]) -> GroupEvent {
        let member = kind == "message.member"
        return GroupEvent(roomID: roomID, seq: seq, eventID: id, kind: kind,
                          actor: GroupActor(kind: member ? "member" : kind == "message.user" ? "user" : "gateway",
                                            id: member ? "laa-cto" : "fixture", profile: member ? "laa-cto" : nil,
                                            displayName: nil, connectionID: nil),
                          authorityEpoch: 1, payload: payload, createdAt: 0)
    }

    static func leaseClient() -> LAAMeetingLeaseClient {
        let generation = UUID().uuidString.lowercased()
        return .init { room, request in
            guard request.action != "release" else { return nil }
            return LAAMeetingGrant(roomId: room, endpointId: request.endpointId, generation: generation,
                                   expiresAt: 12_000, remainingMs: 12_000)
        }
    }

    final class Speaker: LAAChairedVoiceSpeaking {
        let level: (Double) -> Void
        private let audio = VoiceAudioSessionCoordinator.shared
        private var lease: VoiceAudioLease?
        init(level: @escaping (Double) -> Void) { self.level = level }
        func speak(text: String, speakerID: String) async throws {
            lease = try audio.acquire(.meetingPlayback)
            level(0.35)
            try await Task.sleep(for: .seconds(18))
        }
        func stop() {
            if let lease { audio.release(lease); self.lease = nil }
            level(0)
        }
    }
    #endif
}
#endif
