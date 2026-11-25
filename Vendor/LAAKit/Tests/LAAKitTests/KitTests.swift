import CoreText
import Foundation
import SwiftUI
import Testing
import LAAFonts
@testable import LAAKit

struct MarkdownTests {
    @Test func blocksAndKinds() {
        let blocks = LAAMarkdownParser.blocks("""
        # Title
        A paragraph
        continues here.

        - one
          - nested
        2. two
        > quote

        ```swift
        let x = 1
        ```
        ---
        """)
        #expect(blocks.map(\.kind) == [.heading(level: 1), .paragraph, .bullet(depth: 0), .bullet(depth: 1),
                                       .ordered(number: 2, depth: 0), .quote, .code(language: "swift"), .rule])
        #expect(blocks[1].text == "A paragraph continues here.")
        #expect(blocks[6].text == "let x = 1")
    }

    @Test func japaneseSoftBreaksJoinWithoutSpace() {
        #expect(LAAMarkdownParser.blocks("本文は\n続きます。").first?.text == "本文は続きます。")
        #expect(LAAMarkdownParser.blocks("hard  \nbreak").first?.text == "hard\nbreak")
    }

    @Test func streamingKeepsEarlierBlockIDs() {
        let a = LAAMarkdownParser.blocks("First paragraph.\n\nSecond is stre")
        let b = LAAMarkdownParser.blocks("First paragraph.\n\nSecond is streaming now.")
        #expect(a[0].id == b[0].id)
        #expect(a[1].id != b[1].id)
    }

    @Test func unterminatedFenceStillRenders() {
        #expect(LAAMarkdownParser.blocks("```\ncode").first?.kind == .code(language: nil))
    }

    @Test func fileReferencesBecomeLinks() {
        let text = LAAMarkdownParser.inline("See Sources/App/Main.swift:12 and `Sources/Kit/A.swift`.")
        let links = text.runs.compactMap(\.link)
        #expect(links.count == 2)
        #expect(links.allSatisfy { $0.scheme == LAALink.fileScheme })
        let plain = LAAMarkdownParser.inline("`let x = 1` stays code")
        #expect(plain.runs.compactMap(\.link).isEmpty)
    }

    @Test func linkClassification() throws {
        guard case .web = LAALink.classify(try #require(URL(string: "https://example.com"))) else {
            Issue.record("https is web"); return
        }
        #expect(LAALink.displayName(path: "a/b/C.swift", line: 3) == "C.swift:3")
    }
}

struct TypeTests {
    @Test func readingFaceIsNewsreaderWithShipporiCascade() {
        _ = LAAFonts.register()
        let font = LAAType.readingPlatformFont(size: 17, strong: false, italic: false)
        #expect((CTFontCopyFamilyName(font) as String) == "Newsreader")
        let text = "読む" as CFString
        let ja = CTFontCreateForString(font, text, CFRange(location: 0, length: 2))
        #expect((CTFontCopyPostScriptName(ja) as String) == "ShipporiMincho-Medium")
        let strong = LAAType.readingPlatformFont(size: 17, strong: true, italic: false)
        #expect((CTFontCopyPostScriptName(CTFontCreateForString(strong, text, CFRange(location: 0, length: 2))) as String)
                == "ShipporiMincho-SemiBold")
    }

    @Test func readingSizesFollowPlatformCanvas() {
        #expect(LAAType.readingSize(.body, platform: .iphone) == 17)
        #expect(LAAType.readingLine(.body, platform: .iphone) == 28)
        #expect(LAAType.readingSize(.body, platform: .mac) == 16)
        #expect(LAAType.readingLine(.body, platform: .mac) == 26)
        #expect(LAAType.readingLine(.heading, platform: .mac) == 26)
    }
}

/// The reading line box holds for every paragraph, including ones with links (iOS 26 drops `.lineHeight` there).
@MainActor struct LineBoxTests {
    func height(_ view: some View) -> Double {
        ImageRenderer(content: view.frame(width: 300)).cgImage.map { Double($0.height) } ?? -1
    }

    @Test func linkParagraphKeepsTheLineBox() {
        _ = LAAFonts.register()
        let para = "The reading register sets prose in Newsreader with Shippori Mincho for Japanese, on a fixed line box. "
            + "本文は読むための書体で組み、操作の文字はシステムの書体のままにします。"
        let line = LAAType.readingLine(.body)
        let plain = height(LAAMarkdownView(para))
        let linked = height(LAAMarkdownView(para + "[リンク](https://example.com)"))
        #expect(plain.truncatingRemainder(dividingBy: line) == 0, "plain \(plain)")
        #expect(abs(linked - plain) <= 1, "plain \(plain) linked \(linked)")
    }
}
