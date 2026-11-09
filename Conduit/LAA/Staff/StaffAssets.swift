#if LAA_BUILD
import Foundation

/// Profile IDs are stable; display names can be changed on the host.
enum LAAStaff: String, CaseIterable {
    case monet, monetUncensored = "monet-uncensored", monetDots = "monet-dots", argus, cfo, cio, cos, cso, cto

    init?(profile: String) {
        let profile = profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard profile.hasPrefix("laa-") else { return nil }
        self.init(rawValue: String(profile.dropFirst(4)))
    }

    /// Dots replies asynchronously through its text bridge.
    var supportsCalls: Bool { self != .monetUncensored && self != .monetDots }

    var name: String {
        switch self {
        case .monet: return "Monet"
        case .monetUncensored: return "Monet（無検閲）"
        case .monetDots: return "Monet（Dots）"
        case .argus: return "Argus"
        case .cfo: return "Morgan"
        case .cio: return "Sherlock"
        case .cos: return "Merlin"
        case .cso: return "Talos"
        case .cto: return "Ada"
        }
    }

    var role: String {
        switch self {
        case .monet: return "社長秘書・総合アドバイザー"
        case .monetUncensored, .monetDots: return "社長秘書・総合アドバイザー"
        case .argus: return "Head Trader"
        case .cfo: return "CFO"
        case .cio: return "CIO"
        case .cos: return "COS"
        case .cso: return "CSO"
        case .cto: return "CTO"
        }
    }
}

struct StaffAssets: Equatable {
    var avatar: URL?
    var hero: URL?
    var loop: URL?
    var turn: URL?
    var defaultMark: URL?
}

struct StaffAssetResolver {
    let root: URL
    var exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

    static var bundled: StaffAssetResolver {
        StaffAssetResolver(root: Bundle.main.resourceURL ?? Bundle.main.bundleURL)
    }

    func resolve(profile: String) -> StaffAssets {
        let normalized = profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty || normalized == "default" {
            return StaffAssets(defaultMark: present(root.appendingPathComponent("callkit-icon-template-120.png")))
        }
        guard let staff = LAAStaff(profile: normalized) else { return StaffAssets() }
        let name = (staff == .monetDots ? LAAStaff.monet : staff).rawValue
        let directory = root.appendingPathComponent("staff/\(name)", isDirectory: true)
        return StaffAssets(
            avatar: present(directory.appendingPathComponent("\(name)-avatar-512.png")),
            hero: present(directory.appendingPathComponent("\(name)-hero-1024.png")),
            loop: present(directory.appendingPathComponent("\(name)-idle-512.mov")),
            turn: present(directory.appendingPathComponent("\(name)-turn.heic"))
        )
    }

    func isMascot(_ url: URL) -> Bool {
        url.path.hasPrefix(root.appendingPathComponent("staff", isDirectory: true).path)
    }

    private func present(_ url: URL) -> URL? { exists(url) ? url : nil }
}

/// How the mascot's loop runs: `lively` while the employee is answering in
/// chat or speaking on a call, `resting` the rest of the time.
enum StaffAvatarActivity: Equatable {
    case resting, lively

    var playbackRate: Float {
        switch self {
        case .resting: return 1
        case .lively: return 1.4
        }
    }
}

struct StaffAvatarPlaybackPolicy: Equatable {
    var visible: Bool
    var active: Bool
    var reduceMotion: Bool
    var lowPower: Bool
    var scrolling: Bool
    var hasLoop: Bool

    var shouldPlay: Bool {
        visible && active && !reduceMotion && !lowPower && !scrolling && hasLoop
    }

    /// The video is transparent around the mascot, so a still left underneath
    /// shows through it as a second, unmoving mascot.
    func showsStill(videoOnScreen: Bool) -> Bool {
        !(shouldPlay && videoOnScreen)
    }
}
#endif
