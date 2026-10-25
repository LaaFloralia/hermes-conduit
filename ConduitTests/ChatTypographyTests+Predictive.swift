import XCTest
@testable import Conduit

/// Settings > Chat > Predictive (Predictive.swift): what Conduit asks the
/// plugin, how its answers are read, and what the suggestion row offers.
extension ChatTypographyTests {
    func testPredictiveSwitchesAreOffUntilTurnedOn() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PredictiveTests-\(UUID().uuidString)"))
        XCTAssertFalse(Predictive.repliesEnabled(defaults))
        XCTAssertFalse(Predictive.pauseEnabled(defaults))
        XCTAssertFalse(Predictive.followUpEnabled(defaults))
        XCTAssertEqual(Predictive.replyCount(defaults), 3)
        XCTAssertEqual(Predictive.pauseDelay(defaults), 1.2)
        XCTAssertEqual(Predictive.followUpDelay(defaults), 60)
        XCTAssertEqual(Predictive.model(defaults), .fast)
        // A stored value off the menu reads as the default.
        defaults.set(4, forKey: Predictive.replyCountKey)
        XCTAssertEqual(Predictive.replyCount(defaults), 3)
    }

    func testAFollowUpCheckSendsWhatConduitMeasured() throws {
        let facts = Predictive.TurnFacts(lastReplySeconds: 192, onScreenSeconds: 160, check: 2, localTime: "Sunday 09:14")
        let body = Predictive.body(
            kind: .turn, sessionID: "s1", count: 1, facts: facts,
            language: "French", model: .chat, wait: Predictive.turnWait
        )
        XCTAssertEqual(body["kind"] as? String, "turn")
        XCTAssertEqual(body["session_id"] as? String, "s1")
        XCTAssertEqual(body["model"] as? String, "chat")
        let measured = try XCTUnwrap(body["facts"] as? [String: Any])
        XCTAssertEqual(measured["last_reply_s"] as? Int, 192)
        XCTAssertEqual(measured["on_screen_s"] as? Int, 160)
        XCTAssertEqual(measured["check"] as? Int, 2)
        XCTAssertEqual(measured["max_checks"] as? Int, Predictive.maximumChecks)
        XCTAssertEqual(measured["local_time"] as? String, "Sunday 09:14")
        XCTAssertNil(body["draft"])
    }

    func testGuessesComeBestFirst() {
        let guesses = Predictive.guesses([
            ["text": "Remind me tonight", "p": 0.2],
            ["text": "Raise the quota", "p": 0.7],
            ["text": "   ", "p": 0.9],
            ["p": 0.5],
        ])
        XCTAssertEqual(guesses.map(\.text), ["Raise the quota", "Remind me tonight"])
        XCTAssertEqual(Predictive.guesses(nil), [])
        XCTAssertEqual(Predictive.guesses("not a list"), [])
    }

    func testAFollowUpIsOnlyTakenWithItsHiddenTurn() {
        let yes = Predictive.turnAnswer(["take_turn": true, "why": "Worth a check.", "nudge": "[Conduit] …", "ask_again_in_seconds": NSNull()])
        XCTAssertTrue(yes.takeTurn)
        XCTAssertEqual(yes.why, "Worth a check.")
        XCTAssertEqual(yes.nudge, "[Conduit] …")
        XCTAssertFalse(Predictive.turnAnswer(["take_turn": true]).takeTurn)
        let later = Predictive.turnAnswer(["take_turn": false, "ask_again_in_seconds": 5])
        XCTAssertFalse(later.takeTurn)
        XCTAssertEqual(later.askAgain, 30)
        XCTAssertEqual(Predictive.turnAnswer(["take_turn": false, "ask_again_in_seconds": 99_999]).askAgain, 900)
        XCTAssertNil(Predictive.turnAnswer(["take_turn": false]).askAgain)
    }

    func testAContinuationFollowsTheDraftAsItIsTyped() {
        // As asked.
        XCTAssertEqual(Predictive.remainder(of: " the share", askedFor: "Can you delete", draft: "Can you delete"), " the share")
        // The user typed its start meanwhile: the rest is offered.
        XCTAssertEqual(Predictive.remainder(of: " the share", askedFor: "Can you delete", draft: "Can you delete th"), "e share")
        // Typed all of it, or went elsewhere: nothing.
        XCTAssertNil(Predictive.remainder(of: " the share", askedFor: "Can you delete", draft: "Can you delete the share"))
        XCTAssertNil(Predictive.remainder(of: " the share", askedFor: "Can you delete", draft: "Can you delete my"))
        XCTAssertNil(Predictive.remainder(of: " the share", askedFor: "Can you delete", draft: "Could you"))
        XCTAssertEqual(Predictive.inserting(" the share", into: "Can you delete"), "Can you delete the share")
    }

    func testTheLocalTimeNamesTheDayInEnglish() throws {
        let date = try XCTUnwrap(Predictive.date(fromTimestamp: "2026-10-25T13:14:00Z"))
        let toronto = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        XCTAssertEqual(Predictive.localTime(date, timeZone: toronto), "Sunday 09:14")
        XCTAssertNotNil(Predictive.date(fromTimestamp: "2026-10-25T13:14:00.250Z"))
        XCTAssertNil(Predictive.date(fromTimestamp: "yesterday"))
    }

    @MainActor
    func testTheRowShowsRepliesUntilTypingAndTheDraftsGuessesWhileItFits() {
        let store = PredictiveStore()
        let anchor = PredictiveStore.Anchor(sessionID: "s1", messageID: "a1")
        store.setScreen(anchor)
        XCTAssertFalse(store.isShowing)
        store.showReplies([.init(text: "Thanks!", p: 0.8)], for: anchor)
        XCTAssertTrue(store.isShowing)
        XCTAssertEqual(store.currentReplies.map(\.text), ["Thanks!"])

        // Typing folds the row; the replies wait behind its button.
        store.draftChanged("Can you delete")
        XCTAssertTrue(store.isFolded)
        XCTAssertEqual(store.currentReplies, [])
        store.showDraftGuesses(next: [.init(text: " the share", p: 0.6)],
                               replies: [.init(text: "Can you delete old snapshots?", p: 0.5)],
                               for: "Can you delete")
        XCTAssertFalse(store.isFolded)
        XCTAssertEqual(store.currentNext.map(\.text), [" the share"])
        XCTAssertEqual(store.currentReplies.map(\.text), ["Can you delete old snapshots?"])
        store.draftChanged("Can you delete th")
        XCTAssertEqual(store.currentNext.map(\.text), ["e share"])

        // An emptied composer brings the replies back.
        store.draftChanged("")
        XCTAssertFalse(store.isFolded)
        XCTAssertEqual(store.currentReplies.map(\.text), ["Thanks!"])

        // Another reply on screen: the old guesses go.
        store.setScreen(.init(sessionID: "s1", messageID: "a2"))
        XCTAssertFalse(store.isShowing)
        // Hidden in a chat: nothing shows there.
        store.showReplies([.init(text: "Okay", p: 0.5)], for: .init(sessionID: "s1", messageID: "a2"))
        store.hide(sessionID: "s1")
        XCTAssertFalse(store.isShowing)
    }

    @MainActor
    func testATapOnARowThatJustAppearedIsIgnored() {
        let store = PredictiveStore()
        let anchor = PredictiveStore.Anchor(sessionID: "s1", messageID: "a1")
        store.setScreen(anchor)
        store.showReplies([.init(text: "Thanks!", p: 0.8)], for: anchor)
        XCTAssertTrue(store.tapIsGuarded())
        XCTAssertFalse(store.tapIsGuarded(now: Date().addingTimeInterval(Predictive.tapGuard + 0.1)))
    }
}
