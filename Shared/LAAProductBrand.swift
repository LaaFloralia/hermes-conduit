import Foundation

/// Applies only to app-owned display copy, never identifiers, links or chat content.
enum LAAProductBrand {
    /// The name the app uses for itself in text it writes for the user, the
    /// model or other apps: voice prompts, spoken notices and diagnostics.
    /// "Conduit" unless this build is the LAA one, so upstream copy and the
    /// prompts it sends are unchanged.
    static let appName: String = {
        #if LAA_BUILD
        "LAA"
        #else
        "Conduit"
        #endif
    }()

    /// Brands text the app writes for the model or another app, so what the
    /// model says and what the Watch reads out name this build. Upstream
    /// builds get the value back untouched.
    static func display(_ value: String) -> String {
        #if LAA_BUILD
        return value.replacingOccurrences(of: "Hermes Conduit", with: "LAA")
            .replacingOccurrences(of: "Conduit-chan", with: "Ciel")
            .replacingOccurrences(of: "Conduit plugin", with: "Hermes plugin")
            .replacingOccurrences(of: "Conduit", with: "LAA")
        #else
        return value
        #endif
    }
}
