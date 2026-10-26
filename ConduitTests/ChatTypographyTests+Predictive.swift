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
    func testGuessesForADraftTypedOnMeanwhileWaitBehindTheButton() {
        let store = PredictiveStore()
        let anchor = PredictiveStore.Anchor(sessionID: "s1", messageID: "a1")
        store.setScreen(anchor)
        store.draftChanged("Can you delete")
        store.draftChanged("Can you delete th")
        store.showDraftGuesses(next: [.init(text: " the share", p: 0.6)], replies: [], for: "Can you delete")
        XCTAssertTrue(store.isFolded)
        XCTAssertEqual(store.currentNext.map(\.text), ["e share"])
    }

    @MainActor
    func testAFollowUpThatFailedOrWasInterruptedEnds() {
        let events: [StreamEvent] = [
            .messageError(sessionId: "s1", message: "gateway exploded"),
            .messageInterrupted(sessionId: "s1"),
        ]
        for event in events {
            let defaults = makeScratchDefaults("PredictiveFollowUpTests")
            let state = AppState(
                defaults: defaults,
                loadSavedConnection: false,
                sessionPresentationCache: SessionPresentationCache(defaults: defaults)
            )
            state.sessions = [SessionSummary(
                id: "s1", alternateIds: [], title: "s1", model: "Hermes", updatedLabel: "now",
                profile: "default", source: .chat, isActive: false, isArchived: false, lineageRootId: nil
            )]
            state.activeSessionId = "s1"
            state.predictiveFollowUpTurn = ("s1", "Worth a check.", nil)
            state.handleStreamEvent(event)
            XCTAssertNil(state.predictiveFollowUpTurn, "\(event)")
            XCTAssertTrue(state.predictive.followUpReasons.isEmpty)
        }
    }

    @MainActor
    func testAQueuedFollowUpTagsItsOwnReplyNotTheTurnAhead() {
        let defaults = makeScratchDefaults("PredictiveQueuedTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.activeSessionId = "s1"
        state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "now")]
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a1")
        state.predictiveFollowUpQueued = true

        state.messages.append(ChatMessage(id: "a2", role: .assistant, content: "Another client's reply.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertTrue(state.predictive.followUpReasons.isEmpty, "the turn ahead isn't Hermes following up")
        XCTAssertEqual(state.predictiveFollowUpTurn?.after, "a2")
        XCTAssertFalse(state.predictiveFollowUpQueued)

        state.messages.append(ChatMessage(id: "a3", role: .assistant, content: "One more thing.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertEqual(state.predictive.followUpReasons["a3"], "Worth a check.")
        XCTAssertNil(state.predictiveFollowUpTurn)
    }

    /// A system notice merged into the last row anchors no guesses and no
    /// follow-up clock.
    @MainActor
    func testASystemNoticeInTheLastRowIsNotAnAnchor() {
        let defaults = makeScratchDefaults("PredictiveNoticeTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.predictiveSender = { _ in [:] }
        state.activeSessionId = "s1"
        state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "now")]
        XCTAssertEqual(state.predictiveAnchor?.messageID, "a1", "a reply anchors")
        state.messages[0].content = "Context compacted."
        state.messages[0].rawContent = "[System: Context compacted.]"
        XCTAssertNil(state.predictiveAnchor)
    }

    /// A turn ending while the hidden prompt is still on its way is the one
    /// ahead: it isn't tagged, and the follow-up isn't counted as queued
    /// behind another.
    @MainActor
    func testATurnEndingWhileTheFollowUpIsSentIsTheTurnAhead() {
        let defaults = makeScratchDefaults("PredictiveSendingTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.activeSessionId = "s1"
        state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "now")]
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a1")
        state.predictiveFollowUpSending = true

        state.messages.append(ChatMessage(id: "a2", role: .assistant, content: "Another client's reply.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertTrue(state.predictive.followUpReasons.isEmpty, "the turn ahead isn't Hermes following up")
        XCTAssertEqual(state.predictiveFollowUpTurn?.after, "a2")
        XCTAssertTrue(state.predictiveFollowUpAheadEnded)
    }

    @MainActor
    func testLeavingTheChatForTheSidebarDropsAFollowUpsTag() {
        let defaults = makeScratchDefaults("PredictiveSidebarTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.activeSessionId = "s1"
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", nil)
        state.updatePredictiveScreen()
        XCTAssertNotNil(state.predictiveFollowUpTurn, "still on screen")
        state.showSidebar = true
        XCTAssertNil(state.predictiveFollowUpTurn)
    }

    @MainActor
    func testSigningOutForgetsWhatPredictiveKnewOfTheChats() {
        let defaults = makeScratchDefaults("PredictiveSignOutTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let anchor = PredictiveStore.Anchor(sessionID: "s1", messageID: "a1")
        state.predictive.setScreen(anchor)
        state.predictive.showReplies([.init(text: "Thanks!", p: 0.8)], for: anchor)
        state.predictive.draftChanged("Can you delete")
        state.predictive.noteFollowUp(messageID: "a1", why: "Worth a check.")
        state.predictive.hide(sessionID: "s2")
        state.predictiveRepliesAsked = anchor
        state.predictiveDraftAsked = ("s1", "Can you delete")
        state.predictiveFollowUp.anchor = anchor
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", nil)
        state.predictiveReplyEnded = (anchor, Date())
        let pause = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        state.predictivePauseTask = pause
        let generation = state.predictiveGeneration

        state.forgetPredictiveState()

        XCTAssertNotEqual(state.predictiveGeneration, generation, "answers asked before are dropped")

        XCTAssertFalse(state.predictive.isShowing)
        XCTAssertEqual(state.predictive.draft, "")
        XCTAssertTrue(state.predictive.followUpReasons.isEmpty)
        XCTAssertTrue(state.predictive.hiddenSessions.isEmpty)
        XCTAssertNil(state.predictiveRepliesAsked)
        XCTAssertNil(state.predictiveDraftAsked)
        XCTAssertNil(state.predictiveFollowUp.anchor)
        XCTAssertNil(state.predictiveFollowUpTurn)
        XCTAssertNil(state.predictiveReplyEnded)
        XCTAssertNil(state.predictivePauseTask)
        XCTAssertTrue(pause.isCancelled)
    }

    @MainActor
    func testRefreshedChipsAreGuardedAgain() {
        let store = PredictiveStore()
        let anchor = PredictiveStore.Anchor(sessionID: "s1", messageID: "a1")
        store.setScreen(anchor)
        store.showReplies([.init(text: "Thanks!", p: 0.8)], for: anchor)
        let later = Date().addingTimeInterval(Predictive.tapGuard + 0.1)
        XCTAssertFalse(store.tapIsGuarded(now: later))
        store.showReplies([.init(text: "Do it", p: 0.7)], for: anchor)
        XCTAssertTrue(store.tapIsGuarded())
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
