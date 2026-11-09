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

    /// In-app calls (GPT Live). Dots replies through its text bridge; its
    /// phone hands the call to the owner's own ChatGPT dot (`dotCallURL`).
    var supportsCalls: Bool { self != .monetUncensored && self != .monetDots }

    /// Where Dots' phone goes (owner, 2026-11-09).
    var dotCallURL: URL? {
        #if targetEnvironment(macCatalyst)
        dotCallURL(onMac: true, info: Bundle.main.infoDictionary)
        #else
        dotCallURL(onMac: false, info: Bundle.main.infoDictionary)
        #endif
    }

    /// iPhone runs the owner's "Monetに電話" shortcut (ChatGPT's Open your
    /// dot, Call). A release writes the dot's page into Info as
    /// `LAADotsCallURL`; the x-callback-url form then opens that page in
    /// ChatGPT when the shortcut is missing or fails, instead of stopping at
    /// "shortcut not found". Without the page the plain run-shortcut stays.
    /// Mac opens the dot's page in the default browser, since the ChatGPT app
    /// there would take the Local Work connection. That page's link stays out
    /// of this public source: the release writes it into Info as
    /// `LAADotsCallURL` (scripts/laa/brand-bundle.py).
    func dotCallURL(onMac: Bool, info: [String: Any]?) -> URL? {
        guard self == .monetDots else { return nil }
        let page = (info?["LAADotsCallURL"] as? String)
            .flatMap { $0.hasPrefix("https://chatgpt.com/dots/") ? $0 : nil }
        guard onMac else {
            // A page is escaped once, with the unreserved set only, so a
            // receiver that splits the query on `&`, `=`, `+` or `?` still
            // gets the whole link back after decoding.
            guard let page, let error = page.addingPercentEncoding(withAllowedCharacters: Self.dotLinkCharacters) else {
                return Self.dotShortcutURL
            }
            return URL(string: Self.dotShortcutFallback + error)
        }
        guard let page else { return nil }
        return URL(string: page)
    }

    /// Characters left as they are inside the dot link given to `x-error`.
    private static let dotLinkCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static let dotShortcutURL = URL(string: "shortcuts://run-shortcut?name=Monet%E3%81%AB%E9%9B%BB%E8%A9%B1")!
    private static let dotShortcutFallback =
        "shortcuts://x-callback-url/run-shortcut?name=Monet%E3%81%AB%E9%9B%BB%E8%A9%B1&x-error="

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
