#if LAA_BUILD
import Foundation

/// The words of an employee's line without what only the eye reads: emoji,
/// kaomoji and decorative symbols (owner, 2026-11-26). Sound words stay:
/// 「がおー🦖」 reads がおー, 「( ˘꒳˘ ) ﾌﾝｽ」 reads ﾌﾝｽ, 「むむむ… 🐣」 reads むむむ….
/// For VoiceOver labels and for what a call speaks; the screen shows the
/// line as written. Shared with the widget extension (the Live Activity's
/// labels).
enum LAASpokenWords {
    /// The spoken form, trimmed: what a VoiceOver label reads.
    static func label(_ text: String) -> String {
        strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The spoken form. Line breaks stay and spaces are not trimmed, so a
    /// streamed reply can be stripped piece by piece; runs of spaces left
    /// by what was dropped close up to one.
    static func strip(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let characters = Array(withoutKaomojiGroups(Array(text)))
        var output = String.UnicodeScalarView()
        for character in characters {
            for scalar in character.unicodeScalars where !isDecoration(scalar) {
                output.append(scalar)
            }
        }
        var result = String(output)
        // A group whose decoration is all gone leaves its brackets.
        for empty in ["()", "（）", "( )", "（ ）"] {
            result = result.replacingOccurrences(of: empty, with: "")
        }
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result
    }

    // MARK: Kaomoji

    private static let openers: Set<Character> = ["(", "（"]
    private static let closers: Set<Character> = [")", "）"]
    /// A kaomoji's face sits in one bracket pair on one line.
    private static let longestFace = 24

    /// Drops each bracketed face, and the arms stuck to it (`＼(^o^)／`).
    /// A bracket of words stays: （笑）, (注), (1/2).
    private static func withoutKaomojiGroups(_ text: [Character]) -> [Character] {
        var output: [Character] = []
        var index = 0
        while index < text.count {
            let character = text[index]
            guard openers.contains(character),
                  let close = closingIndex(in: text, after: index),
                  isFace(text[(index + 1)..<close]) else {
                output.append(character)
                index += 1
                continue
            }
            // Arms before the face.
            while let last = output.last, isArm(last) { output.removeLast() }
            index = close + 1
            // Arms after it.
            while index < text.count, isArm(text[index]) { index += 1 }
        }
        return output
    }

    private static func closingIndex(in text: [Character], after open: Int) -> Int? {
        var index = open + 1
        while index < text.count, index - open <= longestFace {
            let character = text[index]
            if character.isNewline || openers.contains(character) { return nil }
            if closers.contains(character) { return index }
            index += 1
        }
        return nil
    }

    /// A face: anything outside the words of a sentence, or no letter at all.
    private static func isFace(_ inner: ArraySlice<Character>) -> Bool {
        guard !inner.isEmpty else { return false }
        var hasWord = false
        for character in inner {
            if character.isWhitespace { continue }
            if isWordCharacter(character) { hasWord = true; continue }
            if isSentencePunctuation(character) { continue }
            return true
        }
        return !hasWord
    }

    /// Stuck to a face on either side: not a word, not a space, not the end
    /// of a sentence.
    private static func isArm(_ character: Character) -> Bool {
        !character.isWhitespace && !isWordCharacter(character) && !isSentenceEnd(character)
    }

    /// Japanese and Latin words and their digits (halfwidth ﾌﾝｽ included).
    private static func isWordCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true          // ASCII letters and digits
        case 0xC0...0x24F: return scalar.properties.isAlphabetic          // Latin-1 and Latin Extended letters
        case 0x3041...0x309F: return true                                 // Hiragana
        case 0x30A1...0x30FA, 0x30FC...0x30FF: return true                // Katakana (not ・)
        case 0x3005, 0x3006, 0x3007: return true                          // 々 〆 〇
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true // Kanji
        case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A: return true // Fullwidth letters and digits
        case 0xFF66...0xFF9D: return true                                 // Halfwidth katakana (not ﾞﾟ alone)
        default: return false
        }
    }

    /// Punctuation a sentence uses, which a bracket of words may hold.
    private static func isSentencePunctuation(_ character: Character) -> Bool {
        "、。，．・！？!?,.:;：；/／-ー〜~'\"「」『』…%％&＆+＋#＃".contains(character)
    }

    private static func isSentenceEnd(_ character: Character) -> Bool {
        "、。，．！？!?,.…".contains(character)
    }

    // MARK: Symbols

    /// Emoji, their joiners and modifiers, pictographs and the marks a face
    /// is drawn with. ©, ®, ™, digits, # and * stay (they are emoji only
    /// with a variation selector, which goes).
    private static func isDecoration(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200D, 0xFE0E, 0xFE0F, 0x20E3: return true   // joiner, variation selectors, keycap
        case 0x1F3FB...0x1F3FF: return true                 // skin tones
        case 0xE0020...0xE007F: return true                 // tag sequences (flags)
        case 0x02B0...0x02FF: return true                   // spacing modifier letters (˘ ˊ ˋ)
        case 0x0E50...0x0E59: return true                   // Thai digits (๑)
        case 0x1400...0x167F: return true                   // Canadian syllabics (ᗜ)
        case 0xA000...0xA4CF: return true                   // Yi (꒳)
        case 0x2500...0x27BF: return true                   // box drawing, shapes, dingbats (◕ ★ ♪ ✨)
        case 0x2B00...0x2BFF: return true                   // arrows and shapes (⭐)
        default: break
        }
        let properties = scalar.properties
        if properties.isEmojiPresentation { return true }
        if properties.isEmoji && scalar.value >= 0x2190 { return true }
        switch properties.generalCategory {
        case .modifierSymbol:
            // ´ ¨ ¸ and the like; ASCII ^ and ` stay outside a face.
            return scalar.value > 0x7F
        case .otherSymbol, .mathSymbol:
            return scalar.value >= 0x2190
        default:
            return false
        }
    }
}
#endif
