#if LAA_BUILD
import Foundation

/// Applies only to app-owned display copy, never identifiers, links or chat content.
enum LAAProductBrand {
    static func display(_ value: String) -> String {
        value.replacingOccurrences(of: "Hermes Conduit", with: "LAA")
            .replacingOccurrences(of: "Conduit-chan", with: "Ciel")
            .replacingOccurrences(of: "Conduit plugin", with: "Hermes plugin")
            .replacingOccurrences(of: "Conduit", with: "LAA")
    }
}
#endif
