#if LAA_BUILD
import SwiftUI
import UIKit

/// Draws the note as formatted Markdown while every character stays the
/// original source: block markers become glyphs in the margin, heading marks
/// are hidden, tables are edited outside the text view. Attributes only — the
/// characters are never rewritten, so the IME, selection and undo behave as in
/// any other text view, and saving writes exactly what was read unless the
/// person edited it.
@MainActor
enum LAAMarkdownStyler {
    struct Glyph: Equatable {
        enum Kind: Equatable {
            case bullet
            case checkbox(checked: Bool)
        }
        let lineLocation: Int
        let kind: Kind
    }

    struct Run {
        let range: NSRange
        /// A reset clears what an earlier render put on the line (a heading
        /// that became a paragraph must lose its size); the runs after it add
        /// to that base.
        let reset: Bool
        let attributes: [NSAttributedString.Key: Any]
    }

    struct Output {
        let runs: [Run]
        let glyphs: [Glyph]
    }

    /// Width of one list level's gutter. Glyphs are drawn inside it.
    static let gutter: CGFloat = 28

    // MARK: Fonts

    private static func bodyFont() -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: LAAType.bodySize))
    }

    private static func bodyFont(weight: UIFont.Weight) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: LAAType.bodySize, weight: weight))
    }

    private static func italicBodyFont() -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .italicSystemFont(ofSize: LAAType.bodySize))
    }

    private static func headingFont(_ level: Int) -> UIFont {
        switch level {
        case 1: return UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(ofSize: 21, weight: .bold))
        case 2: return UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 21, weight: .bold))
        default: return UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 21, weight: .bold))
        }
    }

    private static func monoFont(size: CGFloat) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: .regular))
    }

    private static var hiddenFont: UIFont { .systemFont(ofSize: 0.1) }

    private static var clearInk: UIColor { .clear }

    // MARK: Styling

    /// `caretLocation` marks the line being edited: its inline markers stay
    /// visible so they can be typed or removed, while block markers are drawn
    /// as glyphs everywhere.
    /// `limit` restricts the runs that get built to one region (the paragraph
    /// being typed in): the parse is cheap, applying attributes to a long note
    /// on every keystroke is not.
    static func output(for text: String, caretLocation: Int?, limit: NSRange? = nil) -> Output {
        let lines = LAAMarkdownParser.lines(in: text)
        var runs: [Run] = []
        var glyphs: [Glyph] = []
        let ink = UIColor(LAAColor.text)
        let secondary = UIColor(LAAColor.secondaryText)
        let link = UIColor(LAAColor.link)
        let caretLine = caretLocation.flatMap { location in
            lines.first { NSLocationInRange(location, $0.range) || location == $0.range.location }
        }
        let textLength = (text as NSString).length

        for line in lines {
            let level = line.listLevel
            let indent = gutter * CGFloat(level)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.7
            // Markdown's blank source line supplies the paragraph gap. Adding
            // another margin to every source line doubles that space and spreads lists apart.
            paragraph.paragraphSpacing = 0
            paragraph.lineBreakMode = .byWordWrapping

            // Glyphs are collected for every line; the text view draws them
            // from its own geometry, so limiting the runs below cannot make a
            // bullet disappear.
            switch line.kind {
            case .bullet:
                glyphs.append(Glyph(lineLocation: line.range.location, kind: .bullet))
            case .checkbox(let checked):
                glyphs.append(Glyph(lineLocation: line.range.location, kind: .checkbox(checked: checked)))
            default:
                break
            }
            if let limit, NSIntersectionRange(line.range, limit).length == 0,
               !(line.range.length == 0 && NSLocationInRange(line.range.location, limit)) {
                continue
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: bodyFont(),
                .foregroundColor: ink
            ]
            var markerIsGlyph = false

            switch line.kind {
            case .frontmatter:
                attributes[.font] = monoFont(size: 13)
                attributes[.foregroundColor] = secondary
            case .heading(let headingLevel):
                attributes[.font] = headingFont(headingLevel)
                paragraph.paragraphSpacingBefore = 32
                paragraph.paragraphSpacing = 10
                markerIsGlyph = true
            case .bullet, .checkbox:
                if case .checkbox(checked: true) = line.kind { attributes[.foregroundColor] = secondary }
                paragraph.firstLineHeadIndent = indent + gutter
                paragraph.headIndent = indent + gutter
                markerIsGlyph = true
            case .ordered:
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent + gutter
            case .quote:
                paragraph.firstLineHeadIndent = indent + 2
                paragraph.headIndent = indent + gutter
                attributes[.foregroundColor] = secondary
                attributes[.font] = italicBodyFont()
            case .fence, .code:
                attributes[.font] = monoFont(size: 14)
                attributes[.backgroundColor] = UIColor(LAAColor.subtleSurface)
            case .table:
                attributes[.font] = monoFont(size: 13)
                attributes[.foregroundColor] = secondary
            case .raw:
                attributes[.font] = monoFont(size: 14)
                attributes[.foregroundColor] = secondary
            case .rule:
                attributes[.foregroundColor] = UIColor(LAAColor.separator)
            case .blank:
                paragraph.lineHeightMultiple = 1
                paragraph.minimumLineHeight = 12
                paragraph.maximumLineHeight = 12
            case .paragraph:
                break
            }

            attributes[.paragraphStyle] = paragraph
            // The whole line first: paragraph style and block typography. The
            // terminating newline is part of the paragraph, so an empty line
            // (and the space between two blocks) takes its style too.
            let paragraphRange = NSRange(location: line.range.location,
                                         length: line.range.length + (NSMaxRange(line.range) < textLength ? 1 : 0))
            runs.append(Run(range: paragraphRange, reset: true, attributes: attributes))

            if markerIsGlyph, line.markerRange.length > 0 {
                runs.append(Run(range: line.markerInDocument, reset: false,
                                attributes: [.font: hiddenFont, .foregroundColor: clearInk]))
            }
            if case .quote = line.kind, line.markerRange.length > 0 {
                runs.append(Run(range: line.markerInDocument, reset: false,
                                attributes: [.foregroundColor: UIColor(LAAColor.separator)]))
            }

            // Inline spans: hide the markers on every line but the one being
            // edited, so the text reads like the rendered note.
            if case .code = line.kind { continue }
            if case .fence = line.kind { continue }
            if case .frontmatter = line.kind { continue }
            let editingThisLine = caretLine?.range.location == line.range.location
            for span in LAAMarkdownInline.spans(in: line.text, contentRange: line.contentRange) {
                var spanAttributes: [NSAttributedString.Key: Any] = [:]
                switch span.style {
                case .bold: spanAttributes[.font] = bodyFont(weight: .semibold)
                case .italic: spanAttributes[.font] = italicBodyFont()
                case .strike: spanAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                case .code:
                    spanAttributes[.font] = monoFont(size: 15)
                    spanAttributes[.backgroundColor] = UIColor(LAAColor.subtleSurface)
                case .highlight:
                    spanAttributes[.backgroundColor] = UIColor.systemYellow.withAlphaComponent(0.35)
                case .link:
                    spanAttributes[.foregroundColor] = link
                    spanAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                if !spanAttributes.isEmpty {
                    runs.append(Run(range: NSRange(location: line.range.location + span.range.location, length: span.range.length),
                                    reset: false, attributes: spanAttributes))
                }
                if !editingThisLine {
                    let length = (line.text as NSString).length
                    for marker in span.markers where marker.length > 0 && NSMaxRange(marker) <= length {
                        runs.append(Run(range: NSRange(location: line.range.location + marker.location, length: marker.length), reset: false,
                                        attributes: [.font: hiddenFont, .foregroundColor: clearInk]))
                    }
                }
            }
        }
        return Output(runs: runs, glyphs: glyphs)
    }
}
#endif
