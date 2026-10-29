#if LAA_BUILD
import Foundation

/// Profile IDs are stable; display names can be changed on the host.
enum LAAStaff: String, CaseIterable {
    case ciel, argus, cfo, cio, cmo, cos, cso, cto

    init?(profile: String) {
        let profile = profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard profile.hasPrefix("laa-") else { return nil }
        self.init(rawValue: String(profile.dropFirst(4)))
    }

    var name: String {
        switch self {
        case .ciel: return "Ciel"
        case .argus: return "Argus"
        case .cfo: return "Morgan"
        case .cio: return "Sherlock"
        case .cmo: return "Monet"
        case .cos: return "Merlin"
        case .cso: return "Talos"
        case .cto: return "Ada"
        }
    }

    var role: String {
        switch self {
        case .ciel: return "社長秘書・総合アドバイザー"
        case .argus: return "Head Trader"
        case .cfo: return "CFO"
        case .cio: return "CIO"
        case .cmo: return "CMO"
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
        let staffDirectory = root.appendingPathComponent("staff", isDirectory: true)
        // The former Ciel is only a fallback if the entire adopted set is absent.
        let directory: URL
        if !exists(staffDirectory), staff == .ciel {
            directory = root.appendingPathComponent("ciel", isDirectory: true)
        } else {
            directory = staffDirectory.appendingPathComponent(staff.rawValue, isDirectory: true)
        }
        let name = staff.rawValue
        return StaffAssets(
            avatar: present(directory.appendingPathComponent("\(name)-avatar-512.png")),
            hero: present(directory.appendingPathComponent("\(name)-hero-1024.png")),
            loop: present(directory.appendingPathComponent("\(name)-idle-512.mov"))
        )
    }

    private func present(_ url: URL) -> URL? { exists(url) ? url : nil }
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
}
#endif
