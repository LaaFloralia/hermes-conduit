#if LAA_BUILD
import XCTest
import SwiftUI
import UIKit
@testable import Conduit

final class LAAChatDesignTests: XCTestCase {

    func testPeopleRolesAndParentheses() {
        XCTAssertEqual(LAAChatPerson.name("Morgan（CFO）"), "Morgan")
        XCTAssertEqual(LAAChatPerson.role(profile: "laa-monet-dots"), "Secretary")
        XCTAssertEqual(LAAChatPerson.role(profile: "laa-argus"), "Head Trader")
        XCTAssertEqual(LAAChatPerson.role(profile: nil, name: "Ada"), "CTO")
        XCTAssertEqual(LAAChatPerson.role(profile: "laa-cfo", existingRole: "Finance"), "Finance")
        XCTAssertNil(LAAChatPerson.role(profile: "unknown"))
    }

    func testTranscriptHidesWorkButPreservesConversationContent() {
        XCTAssertFalse(LAAChatVisibility.shows(ChatMessage(id: "reason", role: .reasoning, content: "private work", timestamp: "")))
        XCTAssertFalse(LAAChatVisibility.shows(ChatMessage(id: "tool", role: .tool, content: "execution", timestamp: "")))
        XCTAssertTrue(LAAChatVisibility.shows(ChatMessage(id: "reply", role: .assistant, content: "本文", timestamp: "")))
        XCTAssertTrue(LAAChatVisibility.shows(ChatMessage(id: "user", role: .user, content: "依頼", timestamp: "")))
        XCTAssertEqual(LAAChatVisibility.reactions, ["❤️", "👍", "👎", "‼️", "😂", "✅"])
    }

    func testReadReceiptRequiresResponseEvidenceAndOnlyMarksLatestOwnerMessage() {
        let first = ChatMessage(id: "one", role: .user, content: "依頼", timestamp: "1")
        let reply = ChatMessage(id: "reply", role: .assistant, content: "回答", timestamp: "2")
        let next = ChatMessage(id: "two", role: .user, content: "次の依頼", timestamp: "3")
        XCTAssertFalse(LAAChatReadReceipt.wasRead("one", messages: [first]))
        XCTAssertTrue(LAAChatReadReceipt.wasRead("one", messages: [first, reply]))
        XCTAssertFalse(LAAChatReadReceipt.wasRead("one", messages: [first, reply, next]))
        XCTAssertFalse(LAAChatReadReceipt.wasRead("two", messages: [first, reply, next]))
        XCTAssertTrue(LAAChatReadReceipt.wasRead("two", messages: [first, reply, next], hasLiveResponse: true))
    }

    @MainActor
    func testBubbleMenuOwnsHoldWhileKeepingLinkTapsAvailable() {
        let text = SelectableTextView.makeTextView()
        let hold = UILongPressGestureRecognizer()
        let tap = UITapGestureRecognizer()
        text.addGestureRecognizer(hold)
        text.addGestureRecognizer(tap)
        let host = SelectableTextViewHostView(textView: text)
        host.usesMessageMenu = true
        XCTAssertFalse(hold.isEnabled)
        XCTAssertTrue(tap.isEnabled)
        XCTAssertTrue(text.isSelectable)
        host.usesMessageMenu = false
        XCTAssertTrue(hold.isEnabled)
    }

    func testConversationActionsUseJapaneseWithoutExposingInternalNames() {
        XCTAssertEqual(LAAChatLabels.text("Sending…"), "送信中…")
        XCTAssertEqual(LAAChatLabels.groupAction("Disband Group"), "グループを解散")
        XCTAssertEqual(LAAChatLabels.text("Expand editor"), "入力欄を拡大")
        XCTAssertEqual(LAAChatLabels.text("Dictation with Hermes needs a connection to Hermes."), "音声入力にはMacとの接続が必要です。")
    }

    func testDateSectionsUseCalendarDaysAndSkipMissingDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 1)))
        let sameDay = try XCTUnwrap(calendar.date(byAdding: .hour, value: 2, to: day))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .hour, value: -2, to: day))

        XCTAssertTrue(LAAChatDay.startsSection(day, after: nil, calendar: calendar))
        XCTAssertFalse(LAAChatDay.startsSection(sameDay, after: day, calendar: calendar))
        XCTAssertTrue(LAAChatDay.startsSection(day, after: yesterday, calendar: calendar))
        XCTAssertFalse(LAAChatDay.startsSection(nil, after: day, calendar: calendar))
        XCTAssertEqual(LAAChatDay.label(day, now: sameDay, calendar: calendar), "今日")
        XCTAssertEqual(LAAChatDay.label(yesterday, now: day, calendar: calendar), "昨日")
    }

    func testDateSectionUsesPreviousVisibleRow() throws {
        var cache = ChatMessageScrollTargetCache()
        let older = "2026-10-29T12:00:00Z"
        let newer = "2026-10-30T12:00:00Z"
        cache.update(for: [
            ChatMessage(id: "one", role: .user, content: "first", timestamp: older),
            ChatMessage(id: "hidden", role: .assistant, content: "hidden", timestamp: newer),
            ChatMessage(id: "three", role: .assistant, content: "visible", timestamp: newer)
        ])
        let visible = [cache.targets[0], cache.targets[2]]
        XCTAssertNil(LAAChatDay.previousDate(before: visible[0].order, in: visible))
        XCTAssertEqual(LAAChatDay.previousDate(before: visible[1].order, in: visible),
                       try XCTUnwrap(MessageTimestampFormatter.date(from: older)))
    }

    func testLinkIndicatorsKeepCopiesAndMentionsIntact() throws {
        let source = NSMutableAttributedString(string: "Read Notes, then News and @Monet.")
        let plain = source.string as NSString
        source.addAttribute(.link, value: try XCTUnwrap(URL(string: "https://example.com/notes")), range: plain.range(of: "Notes"))
        source.addAttribute(.link, value: try XCTUnwrap(URL(string: "https://example.com/news")), range: plain.range(of: "News"))
        source.addAttribute(.link, value: try XCTUnwrap(URL(string: "conduit-mention://agent/monet")), range: plain.range(of: "@Monet"))
        let displayed = LAALinkDecoration.addingIndicators(to: source)
        XCTAssertEqual(displayed.string, "Read Notes ›, then News › and @Monet.")
        XCTAssertEqual(MarkdownProseRun.copyableText(displayed).string, source.string)
        let arrowRange = (displayed.string as NSString).range(of: "›")
        XCTAssertNotEqual(arrowRange.location, NSNotFound)
        guard arrowRange.location != NSNotFound else { return }
        XCTAssertEqual(displayed.attribute(.underlineStyle, at: arrowRange.location, effectiveRange: nil) as? Int, 0)
        XCTAssertEqual(displayed.attribute(.link, at: arrowRange.location, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com/notes"))

        let rendered = try XCTUnwrap(MarkdownSelectionFormatter.attributedText(
            for: MarkdownParser.parse("Read [Notes](https://example.com/notes) now."),
            foregroundStyle: LAAColor.text, usesAccentSurface: false, newestCharacterOpacities: [],
            usesLAARichContentStyle: true
        ))
        XCTAssertEqual(rendered.string, "Read Notes › now.")
        XCTAssertEqual(MarkdownProseRun.copyableText(rendered).string, "Read Notes now.")
    }

    func testRichContentDefaultsToNeutralTokensOutsideChat() {
        let environment = EnvironmentValues()
        XCTAssertTrue(environment.laaRichContentStyle)
        XCTAssertFalse(environment.laaChatDesign)
        let highlighted = SyntaxHighlighter.highlight("let count = 2", language: "swift", usesLAARichContentStyle: true)
        XCTAssertEqual(highlighted.runs.first?.foregroundColor, LAAColor.link)
    }

    func testNeutralTextAndLinksHaveContrastOnPaperAndCards() {
        func luminance(_ color: UIColor, traits: UITraitCollection) -> CGFloat {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        for scheme in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: scheme)
            for foreground in [LAAColor.text, LAAColor.link, LAAColor.secondaryText] {
                for background in [LAAColor.background, LAAColor.surface, LAAColor.subtleSurface] {
                    let a = luminance(UIColor(foreground), traits: traits)
                    let b = luminance(UIColor(background), traits: traits)
                    let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(scheme) contrast ratio: \(ratio)")
                }
            }
        }
    }

    @MainActor
    func testMarkdownCacheKeepsLAAAndOriginalColorsSeparate() {
        let source = "Same text with **bold** and [link](https://example.com)"
        let original = MarkdownRenderCache.rendering(source: source, recognizesGatewayMedia: false,
            foregroundStyle: .primary, usesAccentSurface: false, isStreaming: false, chatTextSize: .default)
        let laa = MarkdownRenderCache.rendering(source: source, recognizesGatewayMedia: false,
            foregroundStyle: LAAColor.text, usesAccentSurface: false, isStreaming: false,
            chatTextSize: .default, usesLAARichContentStyle: true)
        XCTAssertFalse(original === laa)
        guard let text = laa.selectableText else { return XCTFail("missing selectable text") }
        let range = (text.string as NSString).range(of: "link")
        let color = text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
        let traits = UITraitCollection(userInterfaceStyle: .light)
        XCTAssertEqual(color?.resolvedColor(with: traits), UIColor(LAAColor.link).resolvedColor(with: traits))
    }
}
#endif
