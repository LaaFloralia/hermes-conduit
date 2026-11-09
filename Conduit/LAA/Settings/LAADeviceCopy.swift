#if LAA_BUILD
import Foundation

/// The device a settings line speaks about. Upstream's copy names the paired
/// iPhone; on the Mac the app runs on the Mac itself, so a line that means
/// "here" says "this Mac". The string catalog keys stay upstream's, and only
/// the shown value changes.
enum LAADeviceCopy {
    /// Whether this window is the Mac's own (Catalyst) rather than a phone's.
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    /// Japanese name of this device, for LAA's own copy.
    static var thisDevice: String { isMac ? "このMac" : "このiPhone" }

    /// Upstream settings copy with this device in it, in the language shown.
    /// "This iPhone" means the device the app runs on and becomes the Mac; a
    /// line about another paired device only stops naming it an iPhone. The
    /// dashboard is the app's own Mac here, so it is named the same way
    /// instead of showing the server's internal word.
    static func shown(_ text: String) -> String {
        guard isMac else { return text }
        return text
            .replacingOccurrences(of: "another iPhone", with: "another device")
            .replacingOccurrences(of: "別のiPhone", with: "別の端末")
            .replacingOccurrences(of: "this iPhone", with: "this Mac")
            .replacingOccurrences(of: "This iPhone", with: "This Mac")
            .replacingOccurrences(of: "このiPhone", with: "このMac")
            // "Notifications from this dashboard" on the Mac means the app's
            // own server, so the line only has to name where they arrive.
            .replacingOccurrences(of: "Notifications from this dashboard", with: "Notifications")
            .replacingOccurrences(of: "このダッシュボードからの通知", with: "通知")
            .replacingOccurrences(of: "this dashboard", with: "this Mac")
            .replacingOccurrences(of: "This dashboard", with: "This Mac")
            .replacingOccurrences(of: "このダッシュボード", with: "このMac")
    }
}
#endif
