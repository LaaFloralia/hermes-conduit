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

    /// Brands static text written by the app. Never pass interpolated values,
    /// credentials, addresses, chat content or model responses here.
    /// Upstream builds get the value back untouched.
    static func display(_ value: String) -> String {
        #if LAA_BUILD
        return value.replacingOccurrences(of: "Hermes Conduit", with: "LAA")
            .replacingOccurrences(of: "Conduit-chan", with: "Ciel")
            .replacingOccurrences(of: "Conduit plugin", with: "connection service")
            .replacingOccurrences(of: "Hermes server", with: "Mac")
            .replacingOccurrences(of: "Hermes host", with: "Mac")
            .replacingOccurrences(of: "Conduit", with: "LAA")
            .replacingOccurrences(of: "Hermes", with: "Ciel")
        #else
        return value
        #endif
    }
}
