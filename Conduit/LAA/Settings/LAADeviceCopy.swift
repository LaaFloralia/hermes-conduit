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
    /// Only the phrases that mean the device the app runs on are swapped; a
    /// line about another paired device keeps its own words.
    static func shown(_ text: String) -> String {
        guard isMac else { return text }
        return text
            .replacingOccurrences(of: "another iPhone", with: "another Mac")
            .replacingOccurrences(of: "別のiPhone", with: "別のMac")
            .replacingOccurrences(of: "this iPhone", with: "this Mac")
            .replacingOccurrences(of: "This iPhone", with: "This Mac")
            .replacingOccurrences(of: "このiPhone", with: "このMac")
    }
}
#endif
