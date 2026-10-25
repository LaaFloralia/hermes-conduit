//
//  AppState+Predictive.swift
//  Conduit
//
//  Settings > Chat > Predictive (Predictive.swift): suggested replies once
//  a reply settles, guesses for a paused draft, and Hermes following up
//  while the chat sits on screen. Each question goes to the plugin's
//  `POST /predict`, which answers only this device.
//

import Foundation

@MainActor
extension AppState {
    /// Whether the connected plugin answers predictions.
    var predictiveIsServed: Bool {
        predictiveSender != nil || notifierPlugin.reports(Predictive.capability)
    }

    /// The open chat's last reply, while guesses may show for it: the chat
    /// on screen with Conduit in front, nothing running, no call, and its
    /// last row a reply (not a question or an approval Hermes waits on).
    var predictiveAnchor: PredictiveStore.Anchor? {
        guard predictiveIsServed, isSceneActive, !showSidebar, activeRoomSurface == nil,
              let sessionID = activeSessionId, !sessionID.isEmpty,
              composerChatOnScreen == .live(sessionID),
              !isBusy, !turnState.isRunning, !isVoiceInUse,
              let last = messages.last, last.role == .assistant,
              last.content.contains(where: { !$0.isWhitespace }) else { return nil }
        return PredictiveStore.Anchor(sessionID: sessionID, messageID: last.id)
    }

    /// On each change of the open chat, the scene and the turn
    /// (updateChatOnScreen): the row follows what is on screen, and a new
    /// reply is asked about.
    func updatePredictiveScreen() {
        let anchor = predictiveAnchor
        let previous = predictive.screen
        predictive.setScreen(anchor)
        guard anchor != previous else { return }
        stopPredictiveFollowUpClock()
        guard let anchor else { return }
        // Back on screen: the idle time counts from now.
        predictiveFollowUp.idleSince = Date()
        requestPredictedReplies(for: anchor)
        startPredictiveFollowUpClock(for: anchor)
    }

    /// A turn settled with its reply in place.
    func predictiveTurnSettled(sessionId: String) {
        if let turn = predictiveFollowUpTurn, turn.sessionID == sessionId {
            predictiveFollowUpTurn = nil
            if let reply = messages.last(where: { $0.role == .assistant }) {
                predictive.noteFollowUp(messageID: reply.id, why: turn.why)
                objectWillChange.send()
            }
        }
        if let anchor = predictiveAnchor, anchor.sessionID == sessionId {
            predictiveReplyEnded = (anchor, Date())
        }
        updatePredictiveScreen()
    }

    // MARK: - Asking

    /// Asks the plugin; nil when it can't answer (no plugin, an error, too
    /// slow), which shows nothing.
    func askPredictive(_ body: [String: Any], profile: String, wait: TimeInterval) async -> [String: Any]? {
        if let predictiveSender { return try? await predictiveSender(body) }
        guard let bridge = dashboardTicketBridge else { return nil }
        let path = DashboardPath.withProfile(Predictive.path, profile: profile)
        return try? await bridge.requestJSON(
            path: path, method: "POST", body: body,
            timeoutMilliseconds: Int((wait + 2) * 1_000)
        )
    }

    /// Suggested replies for `anchor`, asked once per reply.
    func requestPredictedReplies(for anchor: PredictiveStore.Anchor, again: Bool = false) {
        guard Predictive.repliesEnabled(), !predictive.hiddenSessions.contains(anchor.sessionID),
              again || predictiveRepliesAsked != anchor else { return }
        predictiveRepliesAsked = anchor
        let count = Predictive.replyCount()
        let body = Predictive.body(
            kind: .replies, sessionID: anchor.sessionID, count: count,
            language: ChatStepSummaries.languageName, model: Predictive.model(), wait: Predictive.repliesWait
        )
        let profile = activeProfile
        Task { [weak self] in
            guard let answer = await self?.askPredictive(body, profile: profile, wait: Predictive.repliesWait),
                  let self, self.predictiveAnchor == anchor else { return }
            let guesses = Array(Predictive.guesses(answer["replies"]).prefix(count))
            guard !guesses.isEmpty else { return }
            self.predictive.showReplies(guesses, for: anchor)
        }
    }

    /// The row's ⋯ > Refresh.
    func refreshPredictions() {
        guard let anchor = predictiveAnchor else { return }
        if predictive.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requestPredictedReplies(for: anchor, again: true)
        } else {
            predictiveDraftAsked = nil
            askAboutDraft(predictive.draft, sessionID: anchor.sessionID)
        }
    }

    /// The row's ⋯ > Hide for this chat.
    func hidePredictionsInOpenChat() {
        guard let sessionID = activeSessionId else { return }
        predictive.hide(sessionID: sessionID)
        stopPredictiveFollowUpClock()
    }

    // MARK: - While I pause

    /// The composer's text changed: typing folds the row, stops the
    /// follow-up clock and, once it pauses, asks about the draft.
    func predictiveDraftChanged(_ text: String) {
        let wasEmpty = predictive.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        predictive.draftChanged(text)
        predictivePauseTask?.cancel()
        predictivePauseTask = nil
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !isEmpty || !wasEmpty {
            // Writing is the opposite of sitting idle: the clock starts over
            // once the composer is empty again.
            predictiveFollowUp.idleSince = Date()
            stopPredictiveFollowUpClock()
            if isEmpty, let anchor = predictiveAnchor { startPredictiveFollowUpClock(for: anchor) }
        }
        guard Predictive.pauseEnabled(), predictiveIsServed, !isEmpty, !text.hasPrefix("/"),
              text.trimmingCharacters(in: .whitespacesAndNewlines).count >= Predictive.minimumDraftCharacters,
              text != predictiveDraftAsked,
              let sessionID = activeSessionId, !sessionID.isEmpty,
              !predictive.hiddenSessions.contains(sessionID), !isBusy, !turnState.isRunning else { return }
        let delay = Predictive.pauseDelay()
        predictivePauseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.predictive.draft == text, self.activeSessionId == sessionID,
                  !self.isBusy else { return }
            self.askAboutDraft(text, sessionID: sessionID)
        }
    }

    /// Asks about `draft` once. The answer counts while it comes within
    /// the wait and the draft still starts with what was asked.
    private func askAboutDraft(_ draft: String, sessionID: String) {
        guard predictiveDraftAsked != draft else { return }
        predictiveDraftAsked = draft
        let body = Predictive.body(
            kind: .draft, sessionID: sessionID, count: Predictive.replyCount(), draft: draft,
            language: ChatStepSummaries.languageName, model: Predictive.model(), wait: Predictive.draftWait
        )
        let profile = activeProfile
        let asked = Date()
        // Not cancelled by more typing: an answer for the start of the draft
        // still offers the rest of a continuation the user is typing.
        Task { [weak self] in
            guard let answer = await self?.askPredictive(body, profile: profile, wait: Predictive.draftWait),
                  let self, self.activeSessionId == sessionID,
                  Date().timeIntervalSince(asked) <= Predictive.draftWait + 1 else { return }
            self.predictive.showDraftGuesses(
                next: Predictive.guesses(answer["next"]),
                replies: Array(Predictive.guesses(answer["replies"]).prefix(Predictive.replyCount())),
                for: draft
            )
        }
    }

    // MARK: - Hermes follows up

    /// Starts (or resumes) the checks for `anchor`'s reply, while the
    /// switch is on and Hermes hasn't spent its follow-up on the user's
    /// last message.
    func startPredictiveFollowUpClock(for anchor: PredictiveStore.Anchor) {
        guard Predictive.followUpEnabled(), predictiveIsServed,
              !predictive.hiddenSessions.contains(anchor.sessionID),
              predictive.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if predictiveFollowUp.anchor != anchor {
            let spent = predictiveFollowUp.spentOn
            predictiveFollowUp = PredictiveFollowUpState(anchor: anchor, spentOn: spent)
        }
        guard !predictiveFollowUp.stopped, predictiveFollowUp.checks < Predictive.maximumChecks,
              predictiveFollowUp.spentOn != predictiveUserMessageKey(anchor.sessionID) else { return }
        let due = predictiveFollowUp.nextCheck
            ?? predictiveFollowUp.idleSince.addingTimeInterval(TimeInterval(Predictive.followUpDelay()))
        predictiveFollowUpTask?.cancel()
        predictiveFollowUpTask = Task { [weak self] in
            let wait = max(0, due.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            await self?.checkPredictiveFollowUp(for: anchor)
        }
    }

    func stopPredictiveFollowUpClock() {
        predictiveFollowUpTask?.cancel()
        predictiveFollowUpTask = nil
    }

    /// The chat and its user's last message, as a follow-up is spent on it.
    private func predictiveUserMessageKey(_ sessionID: String) -> String {
        "\(sessionID)|\(messages.last(where: { $0.role == .user })?.id ?? "")"
    }

    /// One check: asks whether Hermes wants a turn, with what Conduit
    /// measured, and sends the hidden turn or waits as Hermes asked.
    private func checkPredictiveFollowUp(for anchor: PredictiveStore.Anchor) async {
        guard predictiveAnchor == anchor, predictiveFollowUp.anchor == anchor,
              Predictive.followUpEnabled(),
              predictive.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        predictiveFollowUp.checks += 1
        let now = Date()
        let ended = predictiveReplyEnded.flatMap { $0.anchor == anchor ? $0.at : nil }
            ?? messages.last.flatMap { Predictive.date(fromTimestamp: $0.timestamp) }
            ?? predictiveFollowUp.idleSince
        let facts = Predictive.TurnFacts(
            lastReplySeconds: Int(now.timeIntervalSince(ended)),
            onScreenSeconds: Int(now.timeIntervalSince(predictiveFollowUp.idleSince)),
            check: predictiveFollowUp.checks,
            localTime: Predictive.localTime(now)
        )
        let body = Predictive.body(
            kind: .turn, sessionID: anchor.sessionID, count: 1, facts: facts,
            language: ChatStepSummaries.languageName, model: Predictive.model(), wait: Predictive.turnWait
        )
        let answer = await askPredictive(body, profile: activeProfile, wait: Predictive.turnWait)
        // Still the same reply on screen, nobody writing, nothing started.
        guard predictiveAnchor == anchor, predictiveFollowUp.anchor == anchor,
              predictive.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let answer else {
            // A failed check isn't retried for this reply.
            predictiveFollowUp.stopped = true
            return
        }
        let decision = Predictive.turnAnswer(answer)
        if decision.takeTurn, let nudge = decision.nudge {
            predictiveFollowUp.spentOn = predictiveUserMessageKey(anchor.sessionID)
            predictiveFollowUp.stopped = true
            await sendPredictiveFollowUp(nudge, why: decision.why, sessionID: anchor.sessionID)
        } else if let again = decision.askAgain, predictiveFollowUp.checks < Predictive.maximumChecks {
            predictiveFollowUp.nextCheck = Date().addingTimeInterval(TimeInterval(again))
            startPredictiveFollowUpClock(for: anchor)
        } else {
            predictiveFollowUp.stopped = true
        }
    }

    /// The hidden turn: Hermes sees it, the chat doesn't show it, and its
    /// reply wears "Hermes followed up".
    private func sendPredictiveFollowUp(_ nudge: String, why: String, sessionID: String) async {
        guard let client, activeSessionId == sessionID, !isBusy, !turnState.isRunning else { return }
        predictiveFollowUpTurn = (sessionID, why)
        predictive.clear()
        do {
            let outcome = try await client.sendPrompt(sessionID, text: nudge, hidden: true)
            // A turn that started meanwhile took it in: there's no reply of
            // its own to mark.
            if outcome != .accepted { predictiveFollowUpTurn = nil }
        } catch {
            predictiveFollowUpTurn = nil
        }
        // Its reply lands while the user watches: no push for it.
        updateChatOnScreen()
    }
}

@MainActor
extension AppState {
    /// Settings > Chat > Predictive's host line: the fast model, if the
    /// profile names one, and today's count. Nil without the plugin route.
    func loadPredictiveHostStatus() async -> Predictive.HostStatus? {
        guard predictiveIsServed, predictiveSender == nil, let bridge = dashboardTicketBridge else { return nil }
        let path = DashboardPath.withProfile(Predictive.path, profile: activeProfile)
        guard let answer = try? await bridge.requestJSON(path: path, timeoutMilliseconds: 8_000) else { return nil }
        let model = (answer["fast_model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Predictive.HostStatus(fastModel: model, today: (answer["today"] as? NSNumber)?.intValue ?? 0)
    }
}
