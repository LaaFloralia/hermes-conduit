#if LAA_BUILD && DEBUG
import CoreText
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// Each employee's thinking word (D-01, owner 2026-11-26): read from the
/// Bridge's `GET /v1/staff`, picked once per wait (base 7 : alt 3), held for
/// the wait, picked again for the next; 作業中 while a tool runs; Thinking for
/// Work and unknown profiles. VoiceOver and calls read the words without
/// emoji or kaomoji.
@MainActor
final class LAAStaffThinkingTests: XCTestCase {
    private var folder: URL!
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LAAStaffThinkingTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var file: URL { folder.appendingPathComponent("thinking.json") }

    private func store(seed: UInt64 = 8, file: URL? = nil) -> LAAStaffThinking {
        let store = LAAStaffThinking(file: file ?? self.file, random: LAAThinkingRandom(seed: seed), now: { [unowned self] in clock })
        store.apply(LAAStaffList(staff: LAAStaffThinkingFixture.staff))
        return store
    }

    private var monet: LAAThinkingWords { LAAStaffThinkingFixture.staff[0].thinking! }

    // MARK: Reading

    func testBridgeListDecodesAndDropsOnlyWhatIsMalformed() throws {
        let json = """
        {"staff":[
          {"id":"monet","profile":"laa-monet","name":"Monet","thinking":{"base":"Hmm","alt":["A","B","C"]}},
          {"id":"cto","name":"Ada","thinking":{"base":"Gear","alt":[]}},
          {"id":"cfo","profile":"laa-cfo","name":"Morgan","thinking":{"base":"","alt":["x"]}},
          {"id":"cso","profile":"laa-cso","thinking":{"base":"Shield","alt":["", "y"]}},
          {"id":"researcher","profile":"laa-researcher","name":"Fermi"},
          {"profile":"laa-nobody"}
        ]}
        """
        let list = try JSONDecoder().decode(LAAStaffList.self, from: Data(json.utf8))
        XCTAssertEqual(list.staff.map(\.id), ["monet", "cto", "cfo", "cso", "researcher"], "A row without an id drops alone")
        XCTAssertEqual(list.staff[0].thinking?.alt, ["A", "B", "C"])
        XCTAssertEqual(list.staff[1].profile, "laa-cto", "The profile is laa-<id> when the row leaves it out")
        XCTAssertEqual(list.staff[1].thinking?.alt, [], "An empty alt is allowed")
        XCTAssertNil(list.staff[2].thinking, "An empty base drops the thinking, not the row")
        XCTAssertNil(list.staff[3].thinking, "An empty alternative drops the thinking")
        XCTAssertNil(list.staff[4].thinking)
    }

    func testLastGoodListStaysOnTheDeviceForAColdLaunchOffline() throws {
        let first = store()
        XCTAssertEqual(first.words(forProfile: "laa-monet"), monet)
        first.apply(LAAStaffList(staff: []))
        XCTAssertEqual(first.words(forProfile: "laa-monet"), monet, "An empty list (roster unreadable) keeps the last good one")
        let cold = LAAStaffThinking(file: file, random: LAAThinkingRandom(seed: 1))
        XCTAssertEqual(cold.words(forProfile: "LAA-Monet"), monet, "Read back from disk; profiles compare case-insensitively")
        XCTAssertEqual(cold.staff.count, LAAStaffThinkingFixture.staff.count)
        XCTAssertNil(LAAStaffThinking(file: folder.appendingPathComponent("none.json")).words(forProfile: "laa-monet"),
                     "Nothing saved yet: no words")
    }

    // MARK: Picking

    func testPickIsBaseSevenTimesInTenAndEveryAlternativeComesUp() {
        var random = LAAThinkingRandom(seed: 42)
        var counts: [String: Int] = [:]
        for _ in 0..<10_000 { counts[LAAThinkingPick.pick(monet, using: &random), default: 0] += 1 }
        XCTAssertEqual(Double(counts[monet.base] ?? 0) / 10_000, 0.7, accuracy: 0.02)
        for alt in monet.alt {
            XCTAssertEqual(Double(counts[alt] ?? 0) / 10_000, 0.1, accuracy: 0.015, alt)
        }
        XCTAssertEqual(Set(counts.keys), Set([monet.base] + monet.alt))
        let lone = LAAThinkingWords(base: "only", alt: [])!
        for _ in 0..<100 { XCTAssertEqual(LAAThinkingPick.pick(lone, using: &random), "only", "No alternatives: the base") }
    }

    func testSeededPicksAreFixed() {
        var a = LAAThinkingRandom(seed: 8), b = LAAThinkingRandom(seed: 8)
        let first = (0..<20).map { _ in LAAThinkingPick.pick(monet, using: &a) }
        XCTAssertEqual(first, (0..<20).map { _ in LAAThinkingPick.pick(monet, using: &b) })
        XCTAssertEqual(Array(first.prefix(2)), [monet.base, monet.alt[1]], "Seed 8 (the screenshots' fixture): base, then an alternative")
    }

    // MARK: Waits

    func testOneWordHeldForTheWaitAndPickedAgainForTheNext() {
        let words = store()
        let first = words.word(profile: "laa-monet")
        XCTAssertEqual(first, monet.base)
        for _ in 0..<50 { XCTAssertEqual(words.word(profile: "laa-monet"), first, "Held for the whole wait") }
        XCTAssertEqual(words.liveActivityWord(profile: "laa-monet"), first, "The Live Activity says the same")
        words.endWait(profile: "laa-monet")
        clock.addTimeInterval(LAAStaffThinking.resumeGrace + 1)
        let second = words.word(profile: "laa-monet")
        XCTAssertEqual(second, monet.alt[1], "The next wait picks again")
        XCTAssertEqual(words.word(profile: "laa-monet"), second)
    }

    /// The transcript's typing row and the pill read the same hold: the same
    /// word through a wait and the same fresh pick for the next; a chat with
    /// no words keeps the row's 考え中 while the pill says Thinking.
    func testTypingRowSaysThePillsWord() {
        let words = store()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func pill(_ profile: String?) -> String? {
            LAAChatWorking.status(isBusy: true, startedAt: start, toolRunning: false, agents: [], profile: profile, words: words)?.word
        }
        let row = LAAChatWorking.rowPhrase(profile: "laa-monet", words: words)
        XCTAssertEqual(row, monet.base)
        XCTAssertEqual(pill("laa-monet"), row, "The row and the pill say one word")
        XCTAssertEqual(LAAChatWorking.rowPhrase(profile: "laa-monet", words: words), row, "Held for the wait")
        words.endWait(profile: "laa-monet")
        clock.addTimeInterval(LAAStaffThinking.resumeGrace + 1)
        let next = pill("laa-monet")
        XCTAssertEqual(next, monet.alt[1], "The next wait picks again")
        XCTAssertEqual(LAAChatWorking.rowPhrase(profile: "laa-monet", words: words), next, "The row follows the same pick")
        XCTAssertEqual(LAAChatWorking.rowPhrase(profile: "default", words: words), LAACopy.chatThinking)
        XCTAssertEqual(pill("default"), "Thinking")
        XCTAssertEqual(LAAChatWorking.rowPhrase(profile: "laa-researcher", words: words), LAACopy.chatThinking, "An employee with no words")
        XCTAssertEqual(LAAChatWorking.rowPhrase(profile: nil, words: words), LAACopy.chatThinking)
    }

    func testAShortIdleBlipIsTheSameWaitAndASendIsANewOne() {
        let words = store()
        let first = words.word(profile: "laa-monet")
        words.endWait(profile: "laa-monet")
        clock.addTimeInterval(LAAStaffThinking.resumeGrace - 1)
        words.resumeWait(profile: "laa-monet")
        XCTAssertEqual(words.word(profile: "laa-monet"), first, "Idle for a moment and running again: the same wait")
        words.endWait(profile: "laa-monet")
        clock.addTimeInterval(LAAStaffThinking.resumeGrace + 1)
        words.resumeWait(profile: "laa-monet")
        XCTAssertEqual(words.word(profile: "laa-monet"), monet.alt[1], "Running again after the grace: a new wait")
        XCTAssertEqual(words.word(profile: "laa-monet"), monet.alt[1])
        // A view drawn just after the reply reads the held word but does not
        // keep the wait open: the next wait still picks again.
        let drawn = store()
        let held = drawn.word(profile: "laa-monet")
        drawn.endWait(profile: "laa-monet")
        clock.addTimeInterval(1)
        XCTAssertEqual(drawn.word(profile: "laa-monet"), held, "Drawn under the grace: the held word")
        clock.addTimeInterval(LAAStaffThinking.resumeGrace + 3)
        drawn.resumeWait(profile: "laa-monet")
        XCTAssertEqual(drawn.word(profile: "laa-monet"), monet.alt[1], "The next wait is a new pick")
        // A send starts a wait at once, however soon after the last reply.
        let fresh = store(seed: 6)
        XCTAssertEqual(fresh.word(profile: "laa-monet"), monet.base)
        fresh.endWait(profile: "laa-monet")
        XCTAssertEqual(fresh.beginWait(profile: "laa-monet"), monet.alt[0])
        XCTAssertEqual(fresh.word(profile: "laa-monet"), monet.alt[0])
    }

    func testEachEmployeeHoldsItsOwnWait() {
        let words = store()
        let monetWord = words.word(profile: "laa-monet")
        let ada = LAAStaffThinkingFixture.staff[1].thinking!
        let adaWord = words.word(profile: "laa-cto")
        XCTAssertTrue(([ada.base] + ada.alt).contains(adaWord), "Ada's word comes from Ada's words")
        words.endWait(profile: "laa-cto")
        clock.addTimeInterval(10)
        XCTAssertEqual(words.word(profile: "laa-monet"), monetWord, "Ada's reply ending does not end Monet's wait")
    }

    func testThinkingWithoutWordsAndWorkingWhileAToolRuns() {
        let words = store()
        XCTAssertEqual(words.word(profile: "laa-researcher"), "Thinking", "An employee with no thinking yet")
        XCTAssertEqual(words.word(profile: "default"), "Thinking", "A profile that is not an employee")
        XCTAssertEqual(words.word(profile: "laa-monet-uncensored"), "Thinking", "No profile match")
        XCTAssertNil(words.liveActivityWord(profile: "default"), "The Live Activity's own Thinking")
        XCTAssertEqual(LAAStaffThinking(file: nil).word(profile: "laa-monet"), "Thinking", "Bridge never reached, nothing saved")

        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertNil(LAAChatWorking.status(isBusy: false, startedAt: start, toolRunning: false, agents: [], profile: "laa-monet", words: words))
        XCTAssertEqual(LAAChatWorking.status(isBusy: true, startedAt: start, toolRunning: false, agents: [],
                                             profile: "laa-monet", words: words)?.word, monet.base)
        XCTAssertEqual(LAAChatWorking.status(isBusy: true, startedAt: start, toolRunning: true, agents: [],
                                             profile: "laa-monet", words: words)?.word, "作業中", "A tool keeps its progress word")
        XCTAssertEqual(LAAChatWorking.status(isBusy: true, startedAt: start, toolRunning: false, agents: [],
                                             profile: "laa-monet", words: words)?.word, monet.base,
                       "After the tool, the same wait's word")
        XCTAssertEqual(LAAChatWorking.status(isBusy: true, startedAt: start, toolRunning: false, agents: [],
                                             profile: nil, words: words)?.word, "Thinking")
    }

    // MARK: Speech and VoiceOver

    func testSpokenWordsKeepSoundWordsAndDropEmojiAndKaomoji() {
        // laa-design:staff-voice begin hq/roles/roster.yaml and the owner's sample lines (D-01)
        let cases: [(String, String)] = [
            ("むむむ… 🐣", "むむむ…"),
            ("ひらめけ、私 🪄", "ひらめけ、私"),
            ("かちゃかちゃ… ⚙️", "かちゃかちゃ…"),
            ("ふむ、もしや… 🕵️", "ふむ、もしや…"),
            ("ふむ、見定め中 👁️", "ふむ、見定め中"),
            ("がおー🦖 どしん", "がおー どしん"),
            ("( ˘꒳˘ ) ﾌﾝｽ", "ﾌﾝｽ"),
            ("(๑´ڡ`๑)", ""),
            ("できました！( ˘꒳˘ )", "できました！"),
            ("＼(^o^)／ やった", "やった"),
            ("(*´∀`*)", ""),
            ("(・ω・)", ""),
            ("今日は（笑）いい日", "今日は（笑）いい日"),
            ("手順(1/2)を確認", "手順(1/2)を確認"),
            ("Done 👍🏽 ✨❤️ 🇨🇦 👨‍👩‍👧", "Done"),
            ("2*3*4 is 24 © ™ #1", "2*3*4 is 24 © ™ #1"),
            ("1行目 🌙\n2行目", "1行目 \n2行目"),
        ]
        // laa-design:staff-voice end
        for (line, spoken) in cases {
            XCTAssertEqual(LAASpokenWords.label(line), spoken.trimmingCharacters(in: .whitespacesAndNewlines), line)
        }
        // laa-design:staff-voice begin a line of an employee's reply (D-01)
        XCTAssertEqual(LAASpokenWords.strip("1行目 \u{1F319}\n2行目"), "1行目 \n2行目", "Line breaks stay")
        let onlyEmoji = LAAWorkingStatus(word: "\u{1F423}")
        // laa-design:staff-voice end
        for member in LAAStaffThinkingFixture.staff {
            guard let thinking = member.thinking else { continue }
            for word in [thinking.base] + thinking.alt {
                let spoken = LAASpokenWords.label(word)
                XCTAssertFalse(spoken.isEmpty, word)
                XCTAssertFalse(spoken.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }, word)
                XCTAssertTrue(word.hasPrefix(spoken), "Only the emoji at the end goes: \(word)")
            }
        }
        XCTAssertEqual(LAAWorkingStatus(word: monet.base).spokenWord, LAASpokenWords.label(monet.base))
        XCTAssertEqual(onlyEmoji.spokenWord, "Thinking", "Nothing left to read: Thinking")
    }

    func testReadAloudAndCallTextDropKaomoji() {
        // laa-design:staff-voice begin sample employee replies (D-01)
        XCTAssertEqual(SpokenTextFilter.filter("できました ( ˘꒳˘ ) ﾌﾝｽ 🎉"), "できました ﾌﾝｽ ")
        let history = LAAEmployeeCallHistory.context(messages: [
            ChatMessage(id: "u", role: .user, content: "進めて", timestamp: "1"),
            ChatMessage(id: "a", role: .assistant, content: "がおー🦖 終わりました (๑´ڡ`๑)", timestamp: "2"),
        ])
        // laa-design:staff-voice end
        XCTAssertTrue(history.contains("社員: がおー 終わりました"), history)
        XCTAssertFalse(history.unicodeScalars.contains { $0.value == 0x1F996 || $0.value == 0x0E51 })
        for staff in LAAStaff.allCases where staff.supportsCalls {
            XCTAssertTrue(staff.callIdentity.contains("never say or describe them"), staff.rawValue)
        }
    }

    // MARK: Live Activity

    func testLiveActivitySaysTheWaitsWordAndReadsItWithoutEmoji() throws {
        let thinking = HermesTurnAttributes.ContentState(phase: .thinking)
        XCTAssertEqual(HermesTurnCopy.status(thinking, language: "ja", thinkingWord: monet.base), monet.base)
        XCTAssertEqual(HermesTurnCopy.spokenStatus(thinking, language: "ja", thinkingWord: monet.base), LAASpokenWords.label(monet.base))
        XCTAssertEqual(HermesTurnCopy.status(thinking, language: "ja"), "Thinking", "No word: Thinking")
        XCTAssertEqual(HermesTurnCopy.status(thinking, language: "ja", thinkingWord: "  "), "Thinking")
        let tool = HermesTurnAttributes.ContentState(phase: .tool, tool: .web)
        XCTAssertEqual(HermesTurnCopy.status(tool, language: "ja", thinkingWord: monet.base), "Searching the web",
                       "A tool's progress word, never the employee's")

        let link = try XCTUnwrap(URL(string: "conduit://session/s"))
        let attributes = HermesTurnAttributes(chatTitle: "Chat", startedAt: clock, language: "ja", link: link, sessionIDs: ["s"],
                                              profileName: "Monet", thinkingWord: monet.base)
        let decoded = try JSONDecoder().decode(HermesTurnAttributes.self, from: JSONEncoder().encode(attributes))
        XCTAssertEqual(decoded.thinkingWord, monet.base, "Code points survive ActivityKit's coding")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attributes)) as? [String: Any])
        object["thinkingWord"] = nil
        XCTAssertNil(try JSONDecoder().decode(HermesTurnAttributes.self, from: JSONSerialization.data(withJSONObject: object)).thinkingWord,
                     "An activity an older build started still decodes")
    }

    // MARK: Glyphs

    /// Every word of the owner's table and Monet's sample kaomoji, in the
    /// pill's font: no character falls to the LastResort (tofu) font. The
    /// drawn pills are attached for the eye (alignment).
    func testEveryWordHasGlyphsAndIsDrawn() throws {
        // laa-design:staff-voice begin Monet's sample kaomoji (D-01 原文)
        let samples = ["( ˘꒳˘ ) ﾌﾝｽ", "(๑´ڡ`๑)"]
        // laa-design:staff-voice end
        let words = LAAStaffThinkingFixture.staff.compactMap(\.thinking).flatMap { [$0.base] + $0.alt } + samples
        let size = LAAWorkingControlMetrics.labelSize
        let base = CTFontCreateWithFontDescriptor(
            UIFont.systemFont(ofSize: size, weight: .medium).fontDescriptor as CTFontDescriptor, size, nil)
        var missing: [String] = []
        for word in words {
            for character in word where !character.isWhitespace {
                // The base scalar of each character (an emoji's variation
                // selector has no glyph of its own).
                guard let scalar = character.unicodeScalars.first else { continue }
                let text = String(scalar) as CFString
                let font = CTFontCreateForString(base, text, CFRange(location: 0, length: CFStringGetLength(text)))
                let name = CTFontCopyPostScriptName(font) as String
                var units = Array(String(scalar).utf16)
                var glyphs = [CGGlyph](repeating: 0, count: units.count)
                let drawn = CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
                if name == "LastResort" || !drawn {
                    missing.append("\(word): U+\(String(scalar.value, radix: 16, uppercase: true)) (\(name))")
                }
            }
        }
        XCTAssertEqual(missing, [], "Characters with no glyph in the app's font cascade")
        for style in [UIUserInterfaceStyle.light, .dark] {
            let image = try render(style: style, height: CGFloat(words.count) * 60 + 24) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                        LAAWorkingPill(status: LAAWorkingStatus(word: word, startedAt: Date().addingTimeInterval(-12)), openChildren: {})
                    }
                }
                .padding(12)
            }
            attach(image, name: "thinking-words-\(style == .dark ? "dark" : "light")")
        }
    }

    private func render<V: View>(style: UIUserInterfaceStyle, height: CGFloat, @ViewBuilder _ content: () -> V) throws -> UIImage {
        let width: CGFloat = 440
        let root = content()
            .frame(width: width, height: height, alignment: .topLeading)
            .background(LAAColor.background)
            .environment(\.colorScheme, style == .dark ? .dark : .light)
        let host = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<8 {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
