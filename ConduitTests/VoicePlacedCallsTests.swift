//
//  VoicePlacedCallsTests.swift
//  ConduitTests
//
//  A voice conversation the user starts on the phone, placed as a CallKit
//  call (LAA fork, "Place calls as phone calls"). These assert the state
//  machine alone — CallKit and the app are seams here — so every way into
//  and out of a call is checked: the start gate on CallKit's audio, the
//  app's own end, the system call screen's End and Mute, a request CallKit
//  refuses, an end that arrives twice, a conversation that never starts,
//  and a conversation that begins while the last call is still leaving.
//

import AVFAudio
import CallKit
import XCTest
@testable import Conduit

@MainActor
final class VoicePlacedCallsTests: XCTestCase {
    private var kit: FakePlacedCallKit!
    private var session: PlacedCallAudioSession!
    private var audio: VoiceAudioSessionCoordinator!
    private var host: FakePlacedCallHost!
    private var calls: VoicePlacedCalls!

    override func setUp() {
        super.setUp()
        makeCalls()
    }

    /// A bridge with test-sized clocks: the tests don't wait seconds for a
    /// timeout or a follow tick.
    private func makeCalls(
        callAudioTimeout: Duration = .seconds(2),
        voiceStartTimeout: Duration = .seconds(30)
    ) {
        kit = FakePlacedCallKit()
        session = PlacedCallAudioSession()
        audio = VoiceAudioSessionCoordinator(session: session, phoneCalls: { true })
        host = FakePlacedCallHost()
        calls = VoicePlacedCalls(
            callKit: kit,
            audio: audio,
            host: host.callHost,
            callAudioTimeout: callAudioTimeout,
            voiceStartTimeout: voiceStartTimeout,
            followInterval: .milliseconds(20)
        )
    }

    /// A conversation is already running and CallKit has shown and activated
    /// its call.
    private func startAPlacedCall() {
        calls.voiceChanged(running: true)
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
    }

    // MARK: Placing

    func testThePhoneCallIsPlacedWithTheProfilesName() {
        calls.voiceChanged(running: true)

        XCTAssertEqual(calls.phase, .placing)
        XCTAssertEqual(kit.names, ["Ciel"])
        XCTAssertFalse(audio.isInNativeCall, "CallKit hasn't shown the call yet")
    }

    func testTheCallArrivesOnTheCallsAudioPolicy() {
        let categoriesBefore = session.categories.count

        startAPlacedCall()

        XCTAssertEqual(calls.phase, .running)
        XCTAssertTrue(audio.isInNativeCall)
        XCTAssertEqual(audio.conversationConfiguration, .nativeCall)
        XCTAssertEqual(session.categories.count, categoriesBefore + 1, "the call's category, once")
        XCTAssertFalse(session.categories.last?.options.contains(.defaultToSpeaker) ?? true)
        XCTAssertEqual(host.callActiveValues, [true], "the conversation keeps its surface with the phone locked")
    }

    func testTheSettingOffPlacesNoCall() {
        host.isSettingOn = false

        calls.voiceChanged(running: true)

        XCTAssertEqual(calls.phase, .idle)
        XCTAssertTrue(kit.names.isEmpty)
        XCTAssertFalse(audio.isInNativeCall, "the conversation keeps its own earpiece controls")
    }

    func testNoCallWhereCallKitIsNotAvailable() {
        kit.isAvailable = false

        calls.voiceChanged(running: true)

        XCTAssertEqual(calls.phase, .idle)
        XCTAssertTrue(kit.names.isEmpty)
    }

    func testNoCallWhileACallFromHermesIsOnTheScreen() {
        // One call group: a call from Hermes already has the call screen,
        // and the conversation it opened is that call's.
        audio.configureForNativeCall()

        calls.voiceChanged(running: true)

        XCTAssertEqual(calls.phase, .idle)
        XCTAssertTrue(kit.names.isEmpty)
    }

    func testNoCallForAConversationThatEndedBeforeTheViewHeard() {
        host.running = false

        calls.voiceChanged(running: true)

        XCTAssertEqual(calls.phase, .idle)
        XCTAssertTrue(kit.names.isEmpty)
    }

    func testNoCallForAConversationCarPlayOrTheWatchRuns() {
        host.elsewhere = true

        calls.voiceChanged(running: true)

        XCTAssertEqual(calls.phase, .idle)
        XCTAssertTrue(kit.names.isEmpty, "the car's or the wrist's call screen runs it")
    }

    // MARK: The start gate

    /// The conversation waits for CallKit's audio: an engine that starts
    /// before it would run on a session CallKit is about to take.
    func testTheConversationOpensOnlyAfterTheCallsAudio() async {
        let opening = Task { await calls.prepareForVoiceStart() }
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(calls.phase, .placing, "the call was placed before any audio")
        XCTAssertTrue(calls.isWaitingForCallAudio)

        kit.onPlacedCallStarted?()
        XCTAssertEqual(calls.phase, .running)
        XCTAssertTrue(calls.isWaitingForCallAudio, "CallKit has the call but hasn't activated its audio")

        kit.onPlacedCallAudioActivated?()

        let activated = await opening.value
        XCTAssertTrue(calls.canStartVoice(activated))
        XCTAssertFalse(calls.isWaitingForCallAudio)
        XCTAssertTrue(audio.isInNativeCall)
    }

    func testNoConversationOpensWhenTheCallsAudioNeverComes() async {
        makeCalls(callAudioTimeout: .milliseconds(60))
        host.running = false

        let opening = Task { await calls.prepareForVoiceStart() }
        await Task.yield()
        await Task.yield()
        kit.onPlacedCallStarted?()

        let activated = await opening.value

        XCTAssertEqual(activated, .cancelled)
        XCTAssertFalse(calls.isWaitingForCallAudio)
        XCTAssertEqual(calls.phase, .ending)
        XCTAssertEqual(kit.endRequests, 1)
    }

    func testAPlacementCallKitRefusesOpensTheConversationAtOnce() async {
        kit.placeResult = false

        let activated = await calls.prepareForVoiceStart()

        XCTAssertEqual(activated, .withoutCall)
        XCTAssertEqual(calls.phase, .idle)
        XCTAssertFalse(calls.isWaitingForCallAudio)
    }

    /// A conversation that ends as the next one opens leaves its call on the
    /// screen for a moment: the new call waits for it, then is placed.
    func testAPlacementWaitsForTheLastCallToLeave() async {
        startAPlacedCall()
        host.running = false
        calls.voiceChanged(running: false)
        XCTAssertEqual(calls.phase, .ending)

        let opening = Task { await calls.prepareForVoiceStart() }
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(kit.names.count, 1, "no second call while the first is still on its way out")

        kit.onPlacedCallEnded?(false)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(kit.names.count, 2, "the new conversation gets its own call")
        XCTAssertEqual(calls.phase, .placing)

        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        let activated = await opening.value
        XCTAssertTrue(calls.canStartVoice(activated))
    }

    // MARK: A start that doesn't happen

    func testACallCallKitRefusesLeavesTheConversationAlone() {
        kit.placeResult = false

        calls.voiceChanged(running: true)

        XCTAssertEqual(calls.phase, .idle)
        XCTAssertFalse(audio.isInNativeCall, "nothing entered the call's policy")
        XCTAssertTrue(host.callActiveValues.isEmpty)
    }

    func testARequestCallKitRefusesRollsBack() {
        calls.voiceChanged(running: true)

        // The transaction failed after it was asked for: no call is on the
        // screen, and the conversation carries on.
        kit.onPlacedCallEnded?(false)

        XCTAssertEqual(calls.phase, .idle)
        XCTAssertFalse(audio.isInNativeCall)
        XCTAssertEqual(host.endVoiceCount, 0, "the conversation is not the call's to end")
        XCTAssertEqual(host.callActiveValues, [], "it never was on the screen")
        XCTAssertEqual(kit.names.count, 1, "a placement that never showed isn't tried again")
    }

    /// A conversation that failed to start — a refused microphone, an engine
    /// that couldn't — ends its call instead of leaving it alone on the
    /// system's screen.
    func testAFailedStartEndsItsPlacedCall() async {
        host.running = false
        let opening = Task { await calls.prepareForVoiceStart() }
        await Task.yield()
        await Task.yield()
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        _ = await opening.value

        calls.voiceStartFailed()

        XCTAssertEqual(calls.phase, .ending)
        XCTAssertEqual(kit.endRequests, 1)
    }

    func testAFailureAfterTheConversationRanIsLeftToItsOwnEnd() {
        startAPlacedCall()
        // The conversation ran, then something else went wrong: that is an
        // end the follow loop or the app reports, not a start failure.
        host.running = false
        calls.followOnce()
        XCTAssertEqual(kit.endRequests, 1)

        calls.voiceStartFailed()

        XCTAssertEqual(kit.endRequests, 1, "no second request for the same call")
    }

    /// The last resort behind `voiceStartFailed`: a call placed ahead of a
    /// conversation that never arrives doesn't stay on the screen.
    func testACallForAConversationThatNeverStartsEndsAtItsDeadline() async {
        makeCalls(voiceStartTimeout: .milliseconds(60))
        host.running = false

        let opening = Task { await calls.prepareForVoiceStart() }
        await Task.yield()
        await Task.yield()
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        _ = await opening.value

        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(calls.phase, .ending)
        XCTAssertEqual(kit.endRequests, 1)
    }

    // MARK: Ending

    func testTheConversationEndingEndsTheCall() {
        startAPlacedCall()

        host.running = false
        calls.voiceChanged(running: false)

        XCTAssertEqual(calls.phase, .ending)
        XCTAssertEqual(kit.endRequests, 1)
        XCTAssertTrue(audio.isInNativeCall, "CallKit's call is still on the screen")

        // CallKit performed the end Conduit asked for.
        kit.onPlacedCallEnded?(false)

        XCTAssertEqual(calls.phase, .idle)
        XCTAssertFalse(audio.isInNativeCall)
        XCTAssertEqual(host.endVoiceCount, 0, "the conversation ended already")
        XCTAssertEqual(host.callActiveValues, [true, false])
    }

    func testTheScreensEndEndsTheConversation() {
        startAPlacedCall()

        // The user's own End on the system's call screen: Conduit didn't ask.
        kit.onPlacedCallEnded?(true)

        XCTAssertEqual(calls.phase, .idle)
        XCTAssertFalse(audio.isInNativeCall)
        XCTAssertEqual(host.endVoiceCount, 1)
        XCTAssertEqual(host.callActiveValues, [true, false])
    }

    func testAnEndThatCrossesTheAppsOwnEndsOnce() {
        startAPlacedCall()

        host.running = false
        calls.voiceChanged(running: false)
        kit.onPlacedCallEnded?(false)
        // The view changes again for the same end, and one more end arrives
        // late: neither asks CallKit a second time.
        calls.voiceChanged(running: false)
        kit.onPlacedCallEnded?(true)

        XCTAssertEqual(kit.endRequests, 1)
        XCTAssertEqual(host.endVoiceCount, 0)
    }

    func testASecondEndAfterTheScreensEndIsIgnored() {
        startAPlacedCall()
        kit.onPlacedCallEnded?(true)

        calls.voiceChanged(running: false)
        kit.onPlacedCallEnded?(true)

        XCTAssertEqual(kit.endRequests, 0, "CallKit has no call left to end")
        XCTAssertEqual(host.endVoiceCount, 1)
    }

    /// A conversation that begins while the last call is still ending gets
    /// its own call once that call is gone.
    func testACallStartedWhileTheLastOneEndsIsPlacedAfterIt() {
        startAPlacedCall()
        host.running = false
        calls.voiceChanged(running: false)
        XCTAssertEqual(calls.phase, .ending)

        host.running = true
        calls.voiceChanged(running: true)
        XCTAssertEqual(calls.phase, .ending, "the new call waits for the old one")
        XCTAssertEqual(kit.names.count, 1)

        kit.onPlacedCallEnded?(false)

        XCTAssertEqual(kit.names.count, 2)
        XCTAssertEqual(calls.phase, .placing)
    }

    func testAConversationCarriedByACallFromHermesKeepsItsOwnScreen() {
        // An answered call from Hermes ends while a conversation it opened
        // keeps running: the phone places no second call for it.
        startAPlacedCall()
        host.running = false
        calls.voiceChanged(running: false)
        kit.onPlacedCallEnded?(true)
        host.running = true
        audio.configureForNativeCall()

        calls.voiceChanged(running: true)

        XCTAssertEqual(kit.names.count, 1)
        XCTAssertEqual(calls.phase, .idle)
    }

    // MARK: Mute

    func testTheScreensMuteMutesTheVoice() {
        startAPlacedCall()

        kit.onPlacedCallMuteChanged?(true)
        kit.onPlacedCallMuteChanged?(false)

        XCTAssertEqual(host.mutedValues, [true, false])
    }

    /// The system's screen can mute the call before its start is performed.
    func testAScreenMuteWhileTheCallIsPlacingStillMutesTheVoice() {
        calls.voiceChanged(running: true)
        XCTAssertEqual(calls.phase, .placing)

        kit.onPlacedCallMuteChanged?(true)

        XCTAssertEqual(host.mutedValues, [true])
        XCTAssertEqual(calls.reportedMuted, true)

        // The follow loop doesn't echo it back to the screen.
        kit.onPlacedCallStarted?()
        calls.followOnce()
        XCTAssertEqual(kit.mutedReports, [])
    }

    func testAnEarlyMuteIsClearedWhenPlacementFails() {
        calls.voiceChanged(running: true)
        kit.onPlacedCallMuteChanged?(true)
        kit.onPlacedCallEnded?(false)
        XCTAssertEqual(calls.phase, .idle)
        XCTAssertEqual(host.callActiveValues, [false], "clear the call's mute even if it never reached the screen")
    }

    func testTheAppsMuteReachesTheScreenOnce() {
        startAPlacedCall()

        host.muted = true
        calls.followOnce()
        calls.followOnce()

        XCTAssertEqual(kit.mutedReports, [true])
        XCTAssertEqual(host.mutedValues, [], "the mute was the app's: it isn't set back")
    }

    /// A mute CallKit refused is sent again: otherwise the app's microphone
    /// and the system's screen disagree for the rest of the call.
    func testARefusedMuteIsSentAgainUntilCallKitTakesIt() {
        startAPlacedCall()
        kit.muteTakes = [false, true]
        host.muted = true

        calls.followOnce()

        XCTAssertEqual(kit.mutedReports, [true])
        XCTAssertEqual(calls.reportedMuted, false, "a refused mute isn't what the screen shows")

        calls.followOnce()

        XCTAssertEqual(kit.mutedReports, [true, true])
        XCTAssertEqual(calls.reportedMuted, true)

        calls.followOnce()

        XCTAssertEqual(kit.mutedReports, [true, true], "taken: no more requests")
    }

    func testAnOldCallsLateMuteCannotSuppressTheNewCallsMute() {
        startAPlacedCall()
        kit.deferMuteResults = true
        host.muted = true
        calls.followOnce()
        XCTAssertEqual(kit.mutedReports, [true])

        host.running = false
        calls.voiceChanged(running: false)
        kit.onPlacedCallEnded?(false)
        host.running = true
        host.muted = false
        startAPlacedCall()
        XCTAssertEqual(calls.reportedMuted, false)
        kit.completeNextMute(true)
        XCTAssertEqual(calls.reportedMuted, false, "call A's completion cannot change call B")
        host.muted = true
        calls.followOnce()
        XCTAssertEqual(kit.mutedReports, [true, true], "call B still sends its mute")
    }

    func testHangupWhileWaitingCancelsTheOpen() async {
        host.running = false
        let opening = Task { await calls.prepareForVoiceStart() }
        await Task.yield()
        await Task.yield()
        kit.onPlacedCallStarted?()
        kit.onPlacedCallEnded?(true)
        let result = await opening.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(calls.canStartVoice(result))
        XCTAssertEqual(host.endVoiceCount, 1)
    }

    func testAnActivatedCallEndedBeforeTheOpenerResumesCannotStart() async {
        host.running = false
        let opening = Task { await calls.prepareForVoiceStart() }
        await Task.yield()
        await Task.yield()
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        kit.onPlacedCallEnded?(true)
        let result = await opening.value
        XCTAssertFalse(calls.canStartVoice(result))
    }

    func testDeactivatedAudioCannotStartAWaitingConversation() async {
        host.running = false
        let opening = Task { await calls.prepareForVoiceStart() }
        await Task.yield()
        await Task.yield()
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        kit.onPlacedCallAudioDeactivated?()
        let result = await opening.value
        XCTAssertFalse(calls.canStartVoice(result))
        calls.cancelVoiceStart(result)
        XCTAssertEqual(kit.endRequests, 1)
    }

    func testCancellingAnOldStartDoesNotEndItsReplacementCall() async {
        host.running = false
        let firstOpening = Task { await calls.prepareForVoiceStart() }
        for _ in 0..<1_000 where !calls.isWaitingForCallAudio { await Task.yield() }
        XCTAssertTrue(calls.isWaitingForCallAudio)
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        let first = await firstOpening.value
        XCTAssertTrue(calls.canStartVoice(first))

        calls.voiceChanged(running: false)
        kit.onPlacedCallEnded?(false)
        let secondOpening = Task { await calls.prepareForVoiceStart() }
        for _ in 0..<1_000 where !calls.isWaitingForCallAudio { await Task.yield() }
        XCTAssertTrue(calls.isWaitingForCallAudio)
        kit.onPlacedCallStarted?()
        kit.onPlacedCallAudioActivated?()
        let second = await secondOpening.value
        XCTAssertTrue(calls.canStartVoice(second))

        calls.cancelVoiceStart(first)
        XCTAssertEqual(kit.endRequests, 1, "the stale opener must not end the replacement")
        XCTAssertEqual(calls.phase, .running)
        XCTAssertTrue(calls.canStartVoice(second))
        calls.voiceChanged(running: false)
        kit.onPlacedCallEnded?(false)
    }

    func testPlacedCallCannotAcquireAudioUntilCallKitReactivatesIt() throws {
        startAPlacedCall()
        kit.onPlacedCallAudioDeactivated?()
        let activations = session.activations
        XCTAssertThrowsError(try audio.acquire(.conversationCapture))
        XCTAssertEqual(session.activations, activations, "CallKit owns the deactivated session")
        kit.onPlacedCallAudioActivated?()
        let lease = try audio.acquire(.conversationCapture)
        XCTAssertTrue(audio.hasCaptureOwner)
        audio.release(lease)
    }

    func testACallPlacedMutedSaysSoOnTheScreen() {
        host.muted = true

        startAPlacedCall()
        XCTAssertEqual(kit.mutedReports, [], "CallKit starts unmuted; nothing is sent before it has the call")

        calls.followOnce()

        XCTAssertEqual(kit.mutedReports, [true])
        XCTAssertEqual(calls.reportedMuted, true)
    }

    // MARK: The safety net

    func testACallWhoseVoiceEndedWithoutTheViewsIsHungUp() {
        startAPlacedCall()

        // The engine failed, or the conversation ended somewhere the root
        // view didn't see: the call doesn't stay on the screen alone.
        host.running = false
        calls.followOnce()

        XCTAssertEqual(kit.endRequests, 1)
        XCTAssertEqual(calls.phase, .ending)
    }

    func testTheSafetyNetOnlyFollowsACallOfItsOwn() {
        host.running = false

        calls.followOnce()

        XCTAssertEqual(kit.endRequests, 0, "no call was placed, so none is ended")
        XCTAssertEqual(kit.mutedReports, [])
    }
}

// MARK: - What an end CallKit refused leaves to do

@MainActor
final class VoicePlacedCallEndStepTests: XCTestCase {
    /// "No such call" is the only error that means nothing is on the screen.
    func testAnUnknownCallIsGone() {
        XCTAssertEqual(HermesNativeCalls.placedCallEndStep(for: .unknownCallUUID, attempt: 1, attempts: 3), .gone)
    }

    /// Any other refusal leaves a call CallKit still shows: ask again first.
    func testATransientRefusalIsRetried() {
        XCTAssertEqual(HermesNativeCalls.placedCallEndStep(for: .maximumCallGroupsReached, attempt: 1, attempts: 3), .retry)
        XCTAssertEqual(HermesNativeCalls.placedCallEndStep(for: nil, attempt: 1, attempts: 3), .retry)
    }

    /// Out of attempts, the call is reported ended: forgetting it would
    /// leave it on the screen with nothing behind it.
    func testTheLastAttemptReportsTheCallEnded() {
        XCTAssertEqual(
            HermesNativeCalls.placedCallEndStep(for: .maximumCallGroupsReached, attempt: 3, attempts: 3),
            .reportEnded
        )
        XCTAssertEqual(HermesNativeCalls.placedCallEndStep(for: nil, attempt: 4, attempts: 3), .reportEnded)
    }

    func testRefusedEndRetriesThenReportsAndFinishesTheActualCall() async {
        let calls = HermesNativeCalls()
        let id = UUID()
        calls.installPlacedCallForTesting(id)
        calls.placedCallEndRetryDelayForTesting = .milliseconds(1)
        var events: [String] = []
        let finished = expectation(description: "call finished")
        calls.placedCallEndRequestForTesting = { requested in
            XCTAssertEqual(requested, id)
            events.append("request")
            throw NSError(domain: CXErrorDomainRequestTransaction, code: CXErrorCodeRequestTransactionError.Code.maximumCallGroupsReached.rawValue)
        }
        calls.placedCallEndReportForTesting = { reported, reason in
            XCTAssertEqual(reported, id)
            XCTAssertEqual(reason, .failed)
            events.append("report")
        }
        calls.onPlacedCallEnded = { bySystem in
            XCTAssertFalse(bySystem)
            events.append("finished")
            finished.fulfill()
        }
        calls.requestPlacedCallEnd()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(events, ["request", "request", "request", "report", "finished"])
        calls.requestPlacedCallEnd()
        XCTAssertEqual(events.count, 5, "the call was actually removed")
    }

    func testUnknownUUIDFinishesWithoutRetryOrAReport() async {
        let calls = HermesNativeCalls()
        let id = UUID()
        calls.installPlacedCallForTesting(id)
        var requests = 0
        var reports = 0
        let finished = expectation(description: "call finished")
        calls.placedCallEndRequestForTesting = { _ in
            requests += 1
            throw NSError(domain: CXErrorDomainRequestTransaction, code: CXErrorCodeRequestTransactionError.Code.unknownCallUUID.rawValue)
        }
        calls.placedCallEndReportForTesting = { _, _ in reports += 1 }
        calls.onPlacedCallEnded = { _ in finished.fulfill() }
        calls.requestPlacedCallEnd()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(reports, 0)
    }
}

// MARK: - Seams

@MainActor
func makePlacedCallsForTesting(appState: AppState, kit: FakePlacedCallKit, timeout: Duration = .seconds(2), followInterval: Duration = .milliseconds(500)) -> VoicePlacedCalls {
    let audio = VoiceAudioSessionCoordinator(session: PlacedCallAudioSession(), phoneCalls: { true })
    let host = VoicePlacedCallHost(
        isSettingOn: { true },
        isVoiceRunning: { [weak appState] in appState?.isPhoneVoiceCallRunning ?? false },
        displayName: { "Ciel" },
        endVoice: { [weak appState] in appState?.endVoiceForPlacedCall() },
        voiceMuted: { [weak appState] in appState?.nativeCallVoiceMuted },
        setVoiceMuted: { [weak appState] in appState?.setVoiceMutedForNativeCall($0) },
        setCallActive: { [weak appState] in appState?.setPlacedPhoneCallActive($0) },
        runsElsewhere: { false }
    )
    let calls = VoicePlacedCalls(callKit: kit, audio: audio, host: host, callAudioTimeout: timeout, followInterval: followInterval)
    appState.voicePlacedCalls = calls
    return calls
}

@MainActor
final class FakePlacedCallKit: VoicePlacedCallKit {
    var isAvailable = true
    var placeResult = true
    /// What each mute request answers, in order; empty answers "taken".
    var muteTakes: [Bool] = []
    var deferMuteResults = false
    private var muteCompletions: [@MainActor (Bool) -> Void] = []
    private(set) var names: [String] = []
    private(set) var endRequests = 0
    private(set) var mutedReports: [Bool] = []
    var onPlacedCallStarted: (@MainActor () -> Void)?
    var onPlacedCallAudioActivated: (@MainActor () -> Void)?
    var onPlacedCallAudioDeactivated: (@MainActor () -> Void)?
    var onPlacedCallEnded: (@MainActor (Bool) -> Void)?
    var onPlacedCallMuteChanged: (@MainActor (Bool) -> Void)?

    func placeCall(named name: String) -> Bool {
        names.append(name)
        return placeResult
    }

    func requestPlacedCallEnd() {
        endRequests += 1
    }

    func reportPlacedCallMuted(_ muted: Bool, result: @escaping @MainActor (Bool) -> Void) {
        mutedReports.append(muted)
        if deferMuteResults { muteCompletions.append(result); return }
        result(muteTakes.isEmpty ? true : muteTakes.removeFirst())
    }

    func completeNextMute(_ taken: Bool) { muteCompletions.removeFirst()(taken) }
}

/// The app's side of a placed call, and what the call did to it.
@MainActor
private final class FakePlacedCallHost {
    var isSettingOn = true
    var running = true
    var elsewhere = false
    var name = "Ciel"
    var muted: Bool?
    private(set) var mutedValues: [Bool] = []
    private(set) var endVoiceCount = 0
    private(set) var callActiveValues: [Bool] = []

    var callHost: VoicePlacedCallHost {
        VoicePlacedCallHost(
            isSettingOn: { @MainActor in self.isSettingOn },
            isVoiceRunning: { @MainActor in self.running },
            displayName: { @MainActor in self.name },
            endVoice: { @MainActor in self.endVoiceCount += 1; self.running = false },
            voiceMuted: { @MainActor in self.muted },
            setVoiceMuted: { @MainActor muted in
                self.muted = muted
                self.mutedValues.append(muted)
            },
            setCallActive: { @MainActor active in self.callActiveValues.append(active) },
            runsElsewhere: { @MainActor in self.elsewhere }
        )
    }
}

/// Records what the coordinator asked of the session, without touching the
/// process-global AVAudioSession.
final class PlacedCallAudioSession: VoiceAudioSessionControlling {
    struct CategoryCall {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    var isOtherAudioPlaying = true
    private(set) var categories: [CategoryCall] = []
    private(set) var activations = 0

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        categories.append(CategoryCall(category: category, mode: mode, options: options))
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        if active { activations += 1 }
    }
}
