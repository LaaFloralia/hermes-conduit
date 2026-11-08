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
            .replacingOccurrences(of: "Conduit-chan", with: "Monet")
            .replacingOccurrences(of: "Conduit plugin", with: "LAA plugin")
            .replacingOccurrences(of: "Conduitプラグイン", with: "LAAの連携プラグイン")
            .replacingOccurrences(of: "Hermes gateway", with: "LAA background service")
            .replacingOccurrences(of: "Hermes server", with: "LAA server")
            .replacingOccurrences(of: "Hermes host", with: "LAA host")
            .replacingOccurrences(of: "Conduit", with: "LAA")
            .replacingOccurrences(of: "Hermes", with: "LAA")
            .replacingOccurrences(of: "Paseo", with: "Work")
            .replacingOccurrences(of: "パセオ", with: "Work")
        #else
        return value
        #endif
    }
}
