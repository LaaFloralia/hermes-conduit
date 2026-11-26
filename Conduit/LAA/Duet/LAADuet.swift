#if LAA_BUILD
import UIKit

/// Claude Duet, Anthropic's proactive agent, as a contractor (派遣社員,
/// owner 2026-11-26). Duet is reached only in its own app or on claude.ai,
/// with no API, and Anthropic's Consumer Terms forbid automated access to
/// the service. So LAA never types into or reads from Duet: the owner's own
/// tap hands the text over. claude.ai/duet ignores a `?q=` prefill (checked
/// in the owner's Chrome, 2026-11-26), so the hand-off copies the text and
/// opens Duet, where the owner pastes and sends it.
enum LAADuet {
    static let name = "Claude Duet"
    static let maker = "Anthropic"
    /// The list row's identity; not a Hermes profile.
    static let rowID = "duet"

    /// The web Duet. On the Mac the default browser opens it (the owner's
    /// Chrome, in its last used profile). On the iPhone the Duet app claims
    /// only its invite and usage pages, so the web Duet opens; the app
    /// itself and its Shortcuts actions are checked on the device.
    static let webURL = URL(string: "https://claude.ai/duet")!

    /// The words to hand over: trimmed; nothing when only blanks are left.
    static func handoffText(_ draft: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// One tap by the owner: the text (if any) on the clipboard, then Duet.
    /// Returns whether text was copied.
    @MainActor @discardableResult
    static func handOff(_ draft: String,
                        pasteboard: UIPasteboard = .general,
                        open: (URL) -> Void) -> Bool {
        let text = handoffText(draft)
        if let text { pasteboard.string = text }
        open(webURL)
        return text != nil
    }
}
#endif
