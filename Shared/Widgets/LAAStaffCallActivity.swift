#if LAA_BUILD
import Foundation
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// The employee's still in the widget extension (`LAAStaffAvatars.xcassets`,
/// 48 pt) for a profile id such as `laa-cfo`. Dots uses Monet's, as in the
/// app; any other profile has none and the card keeps its status disc.
enum LAAWidgetStaffArt {
    static let known: Set<String> = ["monet", "monet-uncensored", "argus", "cfo", "cio", "cos", "cso", "cto", "soap"]

    static func imageName(profile: String?) -> String? {
        guard let raw = profile?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              raw.hasPrefix("laa-") else { return nil }
        var id = String(raw.dropFirst(4))
        if id == "monet-dots" { id = "monet" }
        return known.contains(id) ? "LAAStaffAvatar-\(id)" : nil
    }

    /// The profile a turn's card belongs to, from the chat link it opens
    /// (`conduit://session/<id>?profile=<name>`): the attributes need no new
    /// field, so cards started by an older build read the same way.
    static func profile(fromLink link: URL) -> String? {
        URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "profile" }?.value
    }
}

/// An in-app employee call (GPT Live) on the Lock Screen and in the Dynamic
/// Island: who is on the line and what the call is doing. Started, updated
/// and ended by the app from the call screen's state
/// (LAAStaffCallActivityController); nothing is pushed, so these keys are the
/// app's own, but keep decoding old values: an unknown phase reads as
/// listening and a missing time as not connected yet.
struct LAAStaffCallAttributes: Codable, Hashable {
    struct ContentState: Codable, Hashable {
        /// A `LAAStaffCallPhase` raw value.
        var phase: String
        /// When the call connected, in seconds since 1970 (nil while connecting).
        var connectedAt: Double?
        /// When the call ended, in seconds since 1970.
        var endedAt: Double?

        init(phase: LAAStaffCallPhase, connectedAt: Date? = nil, endedAt: Date? = nil) {
            self.phase = phase.rawValue
            self.connectedAt = connectedAt?.timeIntervalSince1970
            self.endedAt = endedAt?.timeIntervalSince1970
        }

        var callPhase: LAAStaffCallPhase { LAAStaffCallPhase(rawValue: phase) ?? .listening }
        var connectedDate: Date? { connectedAt.map(Date.init(timeIntervalSince1970:)) }
        var endDate: Date? { endedAt.map(Date.init(timeIntervalSince1970:)) }
    }

    /// The employee's profile id (`laa-cfo`) and name (`Morgan`).
    var profile: String
    var name: String
    /// Opens the call's conversation; nil opens the app.
    var link: URL?
}

#if os(iOS) && !targetEnvironment(macCatalyst)
extension LAAStaffCallAttributes: ActivityAttributes {}
#endif

/// What the call is doing; its words are LAACopy.staffCallState.
enum LAAStaffCallPhase: String, Codable, CaseIterable {
    case connecting, listening, thinking, speaking, muted, ended

    var symbol: String {
        switch self {
        case .connecting: "phone.arrow.up.right"
        case .listening: "waveform"
        case .thinking: "sparkles"
        case .speaking: "speaker.wave.2.fill"
        case .muted: "mic.slash.fill"
        case .ended: "phone.down.fill"
        }
    }

    var isFinished: Bool { self == .ended }
}
#endif
