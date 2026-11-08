#if LAA_BUILD
import SwiftUI

/// The short number the owner says in chat ("T12", "S4", "P2", "R7", "K3").
/// The Bridge assigns it and may not send one yet (an older Bridge); a row then
/// shows nothing rather than a placeholder.
enum LAAWorkRef {
    /// NFKC, no spaces, hyphens or underscores, uppercased. The same folding
    /// the Bridge applies before resolving, so `t12`, `Ｔ１２` and `T-12` are
    /// one number.
    static func normalise(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .filter { !" -_\t\u{3000}".contains($0) }
            .uppercased()
    }

    /// The canonical ref when the whole text is one (`T012` → `T12`), else nil.
    static func parse(_ text: String) -> String? {
        let value = normalise(text)
        guard let match = value.range(of: "^[TSPRK]0*[1-9][0-9]{0,4}$", options: .regularExpression) else { return nil }
        let raw = String(value[match])
        let number = raw.drop { !$0.isNumber }
        guard let digits = Int(number) else { return nil }
        return String(raw.prefix(1)) + String(digits)
    }

    /// What a row shows. Empty and blank values are the same as no ref.
    static func display(_ ref: String?) -> String? {
        guard let ref else { return nil }
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One search rule for the phone and the Mac: a short number finds that
    /// exact number (`t12` → `T12`), and any query also finds the row's
    /// existing text as a case-insensitive substring.
    static func matches(_ query: String, ref: String?, text: [String]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if let wanted = parse(trimmed), parse(ref ?? "") == wanted { return true }
        return text.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}

/// A ref beside a row title: small, muted, monospaced digits, no chrome. It is
/// part of the row's label, so VoiceOver reads "T12" before the title.
struct LAAWorkRefLabel: View {
    let ref: String?

    var body: some View {
        if let value = LAAWorkRef.display(ref) {
            Text(verbatim: value)
                .laaTextStyle(.secondary)
                .monospacedDigit()
                .foregroundStyle(LAAColor.secondaryText)
                .fixedSize()
                .accessibilityIdentifier("work.ref.\(value)")
        }
    }
}
#endif
