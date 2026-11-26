#if LAA_BUILD
import CoreText
import LAAFonts
import LAAKit
import UIKit
import XCTest
@testable import Conduit

/// The reading register (`LAAReadingStyle`): the bundled faces resolve, and
/// every line of mixed Japanese and Latin prose keeps one fixed line box.
final class LAAChatReadingTests: XCTestCase {
    private let large = UITraitCollection(preferredContentSizeCategory: .large)
    private var scale: CGFloat { LAAReadingStyle.platformScale }

    func testBundledFacesResolveByPostScriptName() {
        XCTAssertTrue(LAAReadingStyle.fontsAvailable, "Every kit face registers")
        for face in LAAFonts.faces {
            XCTAssertEqual(UIFont(name: face.postScriptName, size: Conduit.LAAType.bodySize)?.familyName, face.family)
        }
        XCTAssertTrue(LAAReadingStyle.isEnabled)
    }

    func testBodyFaceSizeAndCascade() throws {
        let body = try XCTUnwrap(LAAReadingStyle.font(for: .body, chatScale: 1, traits: large))
        XCTAssertEqual(body.pointSize, LAAReadingStyle.bodySizeToken * scale, accuracy: 0.01)
        XCTAssertEqual(body.familyName, LAAFontFamily.readingLatin)
        let glyphFont = CTFontCreateForString(body as CTFont, "花" as CFString, CFRange(location: 0, length: 1))
        XCTAssertEqual(CTFontCopyFamilyName(glyphFont) as String, LAAFontFamily.readingJapanese)
        let strong = try XCTUnwrap(LAAReadingStyle.uiFont(size: body.pointSize, strong: true))
        let actual = body.withTraits(.traitBold)
        XCTAssertEqual(CTFontCopyVariation(actual as CTFont) as? [Int: Double], CTFontCopyVariation(strong as CTFont) as? [Int: Double])
        XCTAssertTrue(CTFontGetSymbolicTraits(body.withTraits(.traitItalic) as CTFont).contains(.traitItalic))
    }

    func testHeadingCodeAndInlineCodeTokens() throws {
        let h1 = try XCTUnwrap(LAAReadingStyle.font(for: .heading(level: 1), chatScale: 1, traits: large))
        XCTAssertEqual(h1.pointSize, 20 * scale, accuracy: 0.01)
        XCTAssertEqual(h1.familyName, LAAFontFamily.readingLatin)
        XCTAssertEqual(LAAReadingStyle.lineHeight(for: h1), (20 * scale * 26 / 20).rounded())
        let code = try XCTUnwrap(LAAReadingStyle.font(for: .blockCode, chatScale: 1, traits: large))
        XCTAssertEqual(code.pointSize, 13 * scale, accuracy: 0.01)
        XCTAssertEqual(code.lineHeight + LAAReadingStyle.codeBlockLineSpacing(for: code), (13 * scale * 20 / 13).rounded(), accuracy: 0.5)
        let body = try XCTUnwrap(LAAReadingStyle.font(for: .body, chatScale: 1, traits: large))
        let inline = try XCTUnwrap(LAAReadingStyle.inlineCodeFont(for: body))
        XCTAssertEqual(inline.pointSize, (body.pointSize * LAAReadingStyle.inlineCodeScale).rounded())
        XCTAssertNil(LAAReadingStyle.font(for: .tableBody, chatScale: 1, traits: large), "Tables keep the system face")
    }

    func testMixedJapaneseAndLatinLinesShareOneLineBox() throws {
        let body = try XCTUnwrap(LAAReadingStyle.font(for: .body, chatScale: 1, traits: large))
        let box = LAAReadingStyle.lineHeight(for: body)
        XCTAssertEqual(box, (LAAReadingStyle.bodyLineToken * scale).rounded())
        let lines = ["Then the rest, quietly.", "まず午前に決めることを一つ。", "まず Monet が three つ選ぶ。", "「Run」で、テスト（42件）を回す。"]
        var heights: [CGFloat] = []
        for line in lines {
            let text = LAAReadingStyle.lineBoxed(NSAttributedString(string: line, attributes: [.font: body]))
            let style = try XCTUnwrap(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.minimumLineHeight, box)
            XCTAssertEqual(style.maximumLineHeight, box)
            heights.append(text.boundingRect(with: CGSize(width: 2000, height: CGFloat.greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin], context: nil).height.rounded())
        }
        XCTAssertEqual(Set(heights).count, 1, "One line is one box, whichever script it holds: \(heights)")
        XCTAssertEqual(heights.first ?? 0, box, accuracy: 1)

        // Wrapped: n lines take exactly n boxes, Japanese, Latin and code mixed.
        let mixed = NSMutableAttributedString(string: String(repeating: "まず午前に決めることを一つ。Then the rest. ", count: 6),
                                              attributes: [.font: body])
        mixed.append(NSAttributedString(string: "LAAReadingStyle.swift", attributes: [.font: LAAReadingStyle.inlineCodeFont(for: body)!]))
        let wrapped = LAAReadingStyle.lineBoxed(mixed).boundingRect(with: CGSize(width: 400 * scale, height: CGFloat.greatestFiniteMagnitude),
                                                                   options: [.usesLineFragmentOrigin], context: nil).height
        let count = (wrapped / box).rounded()
        XCTAssertGreaterThan(count, 1)
        XCTAssertEqual(wrapped, count * box, accuracy: 1, "Every wrapped line sits on the same box")
    }

    func testLatinTrackingOnlyOnLatin() throws {
        let body = try XCTUnwrap(LAAReadingStyle.font(for: .body, chatScale: 1, traits: large))
        let text = LAAReadingStyle.lineBoxed(NSAttributedString(string: "今日Monet", attributes: [.font: body]))
        XCTAssertNil(text.attribute(.kern, at: 0, effectiveRange: nil), "Japanese keeps 0 tracking")
        let kern = try XCTUnwrap(text.attribute(.kern, at: 2, effectiveRange: nil) as? CGFloat)
        XCTAssertEqual(kern, -0.01 * body.pointSize, accuracy: 0.001)
    }

    func testDynamicTypeScalesTheFaceAndItsBox() throws {
        let big = try XCTUnwrap(LAAReadingStyle.font(for: .body, chatScale: 1,
                                                     traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge)))
        let base = try XCTUnwrap(LAAReadingStyle.font(for: .body, chatScale: 1, traits: large))
        XCTAssertGreaterThan(big.pointSize, base.pointSize * 1.5)
        XCTAssertEqual(LAAReadingStyle.lineHeight(for: big) / big.pointSize,
                       LAAReadingStyle.bodyLineToken / LAAReadingStyle.bodySizeToken, accuracy: 0.05)
    }

    func testRegisterReachesTheTranscriptAndTheComposer() {
        let reading = LAAReadingStyle.reading(.default)
        XCTAssertTrue(reading.laaReading)
        XCTAssertTrue(reading.cacheIdentity.hasSuffix("-r"), "Render caches key the register")
        XCTAssertFalse(LAAReadingStyle.reading(ChatTextAppearance(size: .default, style: .rounded)).laaReading,
                       "A chat style picked in Settings keeps its face")
        XCTAssertEqual(ChatTypography.font(for: .body, appearance: reading, compatibleWith: large).familyName,
                       LAAFontFamily.readingLatin)
        XCTAssertNotEqual(ChatTypography.font(for: .body, appearance: .default, compatibleWith: large).familyName,
                          LAAFontFamily.readingLatin, "Without the register the system face stays")
        XCTAssertTrue(LAAReadingStyle.isReadingFont(ChatTypography.inputFont(for: large, size: .default)))
    }
}
#endif
