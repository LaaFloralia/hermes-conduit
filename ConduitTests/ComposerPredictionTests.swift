import XCTest
@testable import Conduit

final class ComposerPredictionTests: XCTestCase {
    func testRecentSentencesKeepOrderDropDuplicatesAndTrimLongHeads() {
        let long = String(repeating: "あ", count: 120)
        let candidates = ComposerPrediction.recentCandidates([
            "一つ目", " ", "二つ目", "一つ目", long,
        ])
        XCTAssertEqual(candidates.map(\.text), ["一つ目", "二つ目", String(repeating: "あ", count: 80)])
        XCTAssertEqual(candidates.map(\.title), candidates.map(\.text))
    }

    func testRecentSentencesCapAtTwenty() {
        let sentences = (0..<30).map { "文\($0)" }
        XCTAssertEqual(ComposerPrediction.recentCandidates(sentences).count, 20)
    }

    func testBoundaryOnlyAtEmptyPunctuationOrNewline() {
        XCTAssertTrue(ComposerPrediction.isAtBoundary(""))
        XCTAssertTrue(ComposerPrediction.isAtBoundary("今日は。"))
        XCTAssertTrue(ComposerPrediction.isAtBoundary("ok?"))
        XCTAssertTrue(ComposerPrediction.isAtBoundary("一行目\n"))
        XCTAssertFalse(ComposerPrediction.isAtBoundary("今日は"))
    }

    func testComposingSuppressesEveryCandidate() {
        let candidates = ComposerPrediction.candidates(
            draft: "",
            recentSentences: ["一つ目"],
            names: ["Monet"],
            isComposing: true
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testMidSentenceDraftSuppressesCandidates() {
        let candidates = ComposerPrediction.candidates(
            draft: "今日は",
            recentSentences: ["一つ目"],
            names: ["Monet"],
            isComposing: false
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testNamesFollowRecentSentencesWithoutDuplicates() {
        let candidates = ComposerPrediction.candidates(
            draft: "",
            recentSentences: ["Monet"],
            names: ["Monet", "D1", " "],
            isComposing: false
        )
        XCTAssertEqual(candidates.map(\.text), ["Monet", "D1"])
    }

    func testInsertingSpacesOffTheDraft() {
        let candidate = ComposerPrediction.Candidate(text: "続き", title: "続き")
        XCTAssertEqual(ComposerPrediction.inserting("", with: candidate), "続き")
        XCTAssertEqual(ComposerPrediction.inserting("前 ", with: candidate), "前 続き")
        XCTAssertEqual(ComposerPrediction.inserting("前。", with: candidate), "前。 続き")
    }

    func testRowIsOnUntilThisDeviceTurnsItOff() {
        let name = "ComposerPredictionTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        XCTAssertTrue(ComposerPrediction.isEnabled(suite), "A fresh device shows the row.")
        suite.set(false, forKey: ComposerPrediction.preferenceKey)
        XCTAssertFalse(ComposerPrediction.isEnabled(suite))
        suite.set(true, forKey: ComposerPrediction.preferenceKey)
        XCTAssertTrue(ComposerPrediction.isEnabled(suite))
        suite.removePersistentDomain(forName: name)
    }

    /// Settings > Chat > Keyboard writes the key the composer reads, so off
    /// hides the row even while the field has focus.
    func testSwitchOffHidesTheRowEvenInFocus() {
        XCTAssertTrue(ComposerPrediction.showsRow(enabled: true, isFocused: true))
        XCTAssertFalse(ComposerPrediction.showsRow(enabled: false, isFocused: true))
        XCTAssertFalse(ComposerPrediction.showsRow(enabled: true, isFocused: false))
    }
}
