#if LAA_BUILD
import CoreText
import LAAFonts
import LAAKit
import SwiftUI
import UIKit

/// Kit reading tokens and fonts for the UIKit/TextKit transcript and composer.
/// SwiftUI can use the kit's reading face directly; TextKit keeps its attributed line boxes.
enum LAAReadingStyle {
    // MARK: Register

    enum Register: String { case reading, system }
    /// `font.surface.app.reading`. Set to `.system` to put the transcript,
    /// the owner's bubble and the composer back on the system face.
    static let register: Register = .reading

    /// The reading faces are drawn: the register is on and every bundled
    /// face resolved by its PostScript name. A face that fails to register
    /// turns the register off as a whole rather than falling back silently
    /// glyph by glyph.
    static var isEnabled: Bool { register == .reading && fontsAvailable }

    // MARK: Kit metrics (converted to UIKit points on Catalyst)

    static let platformScale = LAAType.platformScale
    static let bodySizeToken = LAAKit.LAAType.readingSize(.body)
    static let bodyLineToken = LAAKit.LAAType.readingLine(.body)
    static let headingSizeToken = LAAKit.LAAType.readingSize(.heading)
    static let headingLineToken = LAAKit.LAAType.readingLine(.heading)
    static let codeBlockSizeToken = LAAType.canvas.codeBlock
    static let codeBlockLineToken = LAAType.canvas.codeBlockLine
    static let inlineCodeScale = LAAType.canvas.codeInline / bodySizeToken
    static let latinTracking = LAAFontFamily.readingTracking
    static let macMeasure = LAACanvas.mac.readingMeasure * platformScale

    /// The reading body size at `traits`' Dynamic Type size and the chat's
    /// own text-size step.
    static func bodySize(chatScale: CGFloat = 1, traits: UITraitCollection? = nil) -> CGFloat {
        let base = bodySizeToken * platformScale
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: base, compatibleWith: traits) * chatScale
    }

    static func headingSize(chatScale: CGFloat = 1, traits: UITraitCollection? = nil) -> CGFloat {
        let base = headingSizeToken * platformScale
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: base, compatibleWith: traits) * chatScale
    }

    /// The fixed line box for text at `size`: 17/28 (Mac 16/26) for prose,
    /// 20/26 for the h1 and h2 sizes.
    static func lineHeight(for font: UIFont) -> CGFloat {
        let ratio = isHeadingSize(font.pointSize) ? headingLineToken / headingSizeToken : bodyLineToken / bodySizeToken
        return (font.pointSize * ratio).rounded()
    }

    // MARK: Fonts

    /// The reading font at `size`: Newsreader with Shippori Mincho for the
    /// Japanese, so a line never mixes in a system fallback.
    static func uiFont(size: CGFloat, strong: Bool = false, italic: Bool = false,
                       traits: UITraitCollection? = nil) -> UIFont? {
        guard isEnabled else { return nil }
        // iOS Bold Text takes the 600 faces; no synthesized bold.
        let strong = strong || traits?.legibilityWeight == .bold || UIAccessibility.isBoldTextEnabled
        let key = FontKey(size: (size * 100).rounded() / 100, strong: strong, italic: italic)
        return cache.font(for: key) {
            if #available(iOS 26, *) {
                let font = LAAKit.LAAType.reading(size: key.size, strong: strong, italic: italic)
                return font.resolve(in: EnvironmentValues().fontResolutionContext).ctFont as UIFont
            }
            // Older deployments have no SwiftUI Font → CTFont bridge.
            let faces = LAAFonts.faces.filter { $0.family == LAAFontFamily.readingLatin }
            let latin = faces.first { $0.postScriptName.contains("Italic") == italic }?.postScriptName
                ?? LAAFontFamily.readingLatin
            let japanese = LAAFonts.faces.filter { $0.family == LAAFontFamily.readingJapanese }
            let cascade = japanese.filter { $0.postScriptName.contains("SemiBold") == strong }
                .map { UIFontDescriptor(fontAttributes: [.name: $0.postScriptName]) }
            let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
            let descriptor = UIFontDescriptor(fontAttributes: [
                .name: latin, .cascadeList: cascade,
                variation: [0x7767_6874: strong ? LAAFontFamily.readingWeightStrong : LAAFontFamily.readingWeight],
            ])
            return UIFont(descriptor: descriptor, size: key.size)
        }
    }

    /// The heading face (h1, h2): reading 600 at the heading size.
    static func headingFont(chatScale: CGFloat, traits: UITraitCollection?) -> UIFont? {
        let size = headingSize(chatScale: chatScale, traits: traits)
        guard let font = uiFont(size: size, strong: true, traits: traits) else { return nil }
        cache.noteHeading(size: font.pointSize)
        return font
    }

    /// `appearance` set in the reading register. A chat text style the
    /// owner picked in Settings (rounded, serif, mono) keeps its own face.
    static func reading(_ appearance: ChatTextAppearance) -> ChatTextAppearance {
        var appearance = appearance
        appearance.laaReading = register == .reading && appearance.style == .standard
        return appearance
    }

    /// The reading font for a transcript role; nil for the roles that keep
    /// the system face (tables, the thinking text, source captions) and
    /// when the register is off.
    static func font(for role: ChatTypography.Role, chatScale: CGFloat, traits: UITraitCollection?) -> UIFont? {
        guard isEnabled else { return nil }
        switch role {
        case .body:
            return uiFont(size: bodySize(chatScale: chatScale, traits: traits), traits: traits)
        case .quote:
            return uiFont(size: bodySize(chatScale: chatScale, traits: traits), italic: true, traits: traits)
        case .heading(let level) where level <= 2:
            return headingFont(chatScale: chatScale, traits: traits)
        case .heading:
            return uiFont(size: bodySize(chatScale: chatScale, traits: traits), strong: true, traits: traits)
        case .blockCode:
            let size = UIFontMetrics(forTextStyle: .body).scaledValue(for: codeBlockSizeToken * platformScale,
                                                                      compatibleWith: traits) * chatScale
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .tableHeader, .tableBody, .thinking, .sourceCode:
            return nil
        }
    }

    /// The spacing that puts a code block's lines on its 13/20 box.
    static func codeBlockLineSpacing(for font: UIFont) -> CGFloat {
        max(0, (font.pointSize * codeBlockLineToken / codeBlockSizeToken).rounded() - font.lineHeight)
    }

    static func isReadingFont(_ font: UIFont) -> Bool {
        font.familyName == LAAFontFamily.readingLatin || font.familyName == LAAFontFamily.readingJapanese
    }

    /// `font` made strong or italic within the reading faces; nil when it
    /// is not a reading font.
    static func withTraits(_ font: UIFont, _ traits: UIFontDescriptor.SymbolicTraits) -> UIFont? {
        guard isEnabled, isReadingFont(font) else { return nil }
        let axes = CTFontCopyVariation(font as CTFont) as? [Int: Double]
        let strong = traits.contains(.traitBold) || (axes?[0x7767_6874] ?? 0) >= LAAFontFamily.readingWeightStrong
        let italic = traits.contains(.traitItalic) || font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        return uiFont(size: font.pointSize, strong: strong, italic: italic)
    }

    /// Inline code inside reading text: mono at 0.88 of it.
    static func inlineCodeFont(for font: UIFont) -> UIFont? {
        guard isEnabled, isReadingFont(font) else { return nil }
        return .monospacedSystemFont(ofSize: (font.pointSize * inlineCodeScale).rounded(), weight: .regular)
    }

    // MARK: Registration

    static let fontsAvailable = LAAFonts.register().isEmpty

    // MARK: Line box

    /// Gives every paragraph set in the reading faces one fixed line box
    /// (min = max line height) with the baseline offset into its middle, and
    /// Latin runs their −0.01 em tracking. A line's height then never moves
    /// when its first kanji or a fallback glyph arrives while streaming.
    /// Paragraphs in other faces (code, tables, labels) are left as they are.
    static func lineBoxed(_ text: NSAttributedString) -> NSAttributedString {
        guard isEnabled, text.length > 0 else { return text }
        let string = text.string as NSString
        var result: NSMutableAttributedString?
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            var lineHeight: CGFloat = 0
            var readingLineHeight: CGFloat = 0
            text.enumerateAttribute(.font, in: paragraph) { value, _, _ in
                guard let font = value as? UIFont, isReadingFont(font) else { return }
                if lineHeight < Self.lineHeight(for: font) {
                    lineHeight = Self.lineHeight(for: font)
                    readingLineHeight = font.lineHeight
                }
            }
            guard lineHeight > 0 else { continue }
            let output = result ?? NSMutableAttributedString(attributedString: text)
            result = output
            text.enumerateAttribute(.paragraphStyle, in: paragraph) { value, range, _ in
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.minimumLineHeight = lineHeight
                style.maximumLineHeight = lineHeight
                style.lineSpacing = 0
                style.lineHeightMultiple = 0
                output.addAttribute(.paragraphStyle, value: style, range: range)
            }
            // One offset for the whole paragraph keeps every run, Japanese,
            // Latin and code, on the same baseline.
            output.addAttribute(.baselineOffset, value: baselineOffset(lineHeight: lineHeight, fontLineHeight: readingLineHeight),
                                range: paragraph)
            trackLatin(in: output, paragraph: paragraph, original: text)
        }
        return result ?? text
    }

    /// Where the glyphs sit in the box: TextKit puts the extra height of a
    /// raised line above the glyphs, so half of it is given back.
    static func baselineOffset(lineHeight: CGFloat, fontLineHeight: CGFloat) -> CGFloat {
        max(0, (lineHeight - fontLineHeight) / 4)
    }

    private static func trackLatin(in output: NSMutableAttributedString, paragraph: NSRange, original: NSAttributedString) {
        let string = original.string as NSString
        original.enumerateAttribute(.font, in: paragraph) { value, range, _ in
            guard let font = value as? UIFont, isReadingFont(font), original.attribute(.kern, at: range.location, effectiveRange: nil) == nil else { return }
            let kern = latinTracking * font.pointSize
            var start: Int?
            for index in range.location...NSMaxRange(range) {
                let latin = index < NSMaxRange(range) && isLatin(string.character(at: index))
                if latin, start == nil { start = index }
                if !latin, let run = start {
                    output.addAttribute(.kern, value: kern, range: NSRange(location: run, length: index - run))
                    start = nil
                }
            }
        }
    }

    /// Basic Latin letters and digits up to Latin Extended-B; spaces and
    /// Japanese keep 0.
    static func isLatin(_ unit: unichar) -> Bool {
        (0x21...0x24F).contains(Int(unit))
    }

    // MARK: Heading sizes and font cache

    private static func isHeadingSize(_ size: CGFloat) -> Bool { cache.isHeading(size: size) }

    private struct FontKey: Hashable {
        let size: CGFloat
        let strong: Bool
        let italic: Bool
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var fonts: [FontKey: UIFont] = [:]
        private var headings: Set<Int> = []

        func font(for key: FontKey, make: () -> UIFont) -> UIFont {
            lock.lock(); defer { lock.unlock() }
            if let font = fonts[key] { return font }
            let font = make()
            if fonts.count > 256 { fonts.removeAll() }
            fonts[key] = font
            return font
        }

        func noteHeading(size: CGFloat) {
            lock.lock(); defer { lock.unlock() }
            headings.insert(Int((size * 100).rounded()))
        }

        func isHeading(size: CGFloat) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return headings.contains(Int((size * 100).rounded()))
        }
    }

    private static let cache = Cache()
}

extension Font {
    /// The reading face for SwiftUI text (the owner's quick echoes), the
    /// system body when the register is off.
    static func laaReading(size: CGFloat? = nil) -> Font {
        LAAKit.LAAType.reading(size: size ?? LAAReadingStyle.bodySize())
    }
}
#endif
