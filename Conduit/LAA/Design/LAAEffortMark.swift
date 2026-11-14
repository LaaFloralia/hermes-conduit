#if LAA_BUILD
import SwiftUI

/// The effort values and their names, shared by Work and Chat. Rendering
/// only: the wire values ("xhigh") are not changed.
enum LAAEffort {
    static let order = ["low", "medium", "high", "xhigh", "max"]

    static func rank(_ value: String) -> Int { value == "ultracode" ? 5 : order.firstIndex(of: value) ?? 9 }

    /// XHigh and Max: the two settings that think longest.
    static func isDeep(_ value: String?) -> Bool { value == "xhigh" || value == "max" || value == "ultracode" }

    /// The effort kept when the model changes: the same one if the new model
    /// has it, else High, else the nearest by rank (the lower on a tie). Nil
    /// only when the new model offers none.
    static func carried(_ effort: String?, into available: [String]) -> String? {
        if let effort, available.contains(effort) { return effort }
        if available.contains("high") { return "high" }
        let target = rank(effort ?? "high") == 9 ? rank("high") : rank(effort ?? "high")
        return available.min { lhs, rhs in
            let left = abs(rank(lhs) - target), right = abs(rank(rhs) - target)
            return left != right ? left < right : rank(lhs) < rank(rhs)
        }
    }

    static func name(_ raw: String?) -> String? {
        switch raw {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "XHigh"
        case "max": return "Max"
        case "ultracode": return "Ultra Code"
        case let value?: return value.isEmpty ? nil : value
        case nil: return nil
        }
    }
}

/// XHigh polishes the glass, Max and Ultra Code make it crystal (LAAFinish):
/// the higher the effort, the more particles; High and below stay plain.
extension LAAEffort {
    static func finish(_ value: String?) -> LAAFinish {
        switch value {
        case "xhigh": .polished
        case "max", "ultracode": .crystal
        default: .plain
        }
    }
}

/// The effort beside the model: its name alone, in ink (owner, 2026-11-14:
/// no meter beside it).
struct LAAEffortLabel: View {
    let effort: String
    var current = true

    var body: some View {
        Text(verbatim: LAAEffort.name(effort) ?? effort)
            .fontWeight(.medium)
            .foregroundStyle(current ? LAAColor.text : LAAColor.secondaryText)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The effort rows of a menu: the name, and for the deep settings a short
/// line under it.
enum LAAEffortMenu {
    static func subtitle(_ effort: String) -> String? {
        switch effort {
        case "xhigh": "より深く考える"
        case "max": "最も深く考える"
        case "ultracode": "複数のエージェントで取り組む"
        default: nil
        }
    }

    /// One effort row: a Toggle, so the system draws the current value's check
    /// at the leading edge.
    struct Row: View {
        let effort: String
        let selected: Bool
        var identifier: String? = nil
        let choose: () -> Void

        var body: some View {
            Toggle(isOn: Binding(get: { selected }, set: { on in if on { choose() } })) {
                Text(verbatim: LAAEffort.name(effort) ?? effort)
                if let subtitle = LAAEffortMenu.subtitle(effort) { Text(verbatim: subtitle) }
            }
            .accessibilityIdentifier(identifier ?? "work.session.effort.\(effort)")
        }
    }
}
#endif
