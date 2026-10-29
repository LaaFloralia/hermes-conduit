//
//  VoicePlacedCallsTests.swift
//  ConduitTests
//
//  A voice conversation the user starts on the phone, placed as a CallKit
//  call (LAA fork, "Place calls as phone calls"). These assert the state
//  machine alone — CallKit and the app are seams here — so every way out of
//  a call is checked: the app's own end, the system call screen's End and
//  Mute, a request CallKit refuses, and an end that arrives twice.
//

import AVFAudio
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
        kit = FakePlacedCallKit()
        session = PlacedCallAudioSession()
        audio = VoiceAudioSessionCoordinator(session: session, phoneCalls: { true })
        host = FakePlacedCallHost()
        calls = VoicePlacedCalls(callKit: kit, audio: audio, host: host.callHost)
    }

    /// A conversation is running and CallKit has shown its call.
    private func startAPlacedCall() {
        calls.voiceChanged(running: true)
        kit.onPlacedCallStarted?()
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
    }

    // MARK: Ending

    func testTheConversationEndingEndsTheCall() {
        startAPlacedCall()

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

    // MARK: Mute

    func testTheScreensMuteMutesTheVoice() {
        startAPlacedCall()

        kit.onPlacedCallMuteChanged?(true)
        kit.onPlacedCallMuteChanged?(false)

        XCTAssertEqual(host.mutedValues, [true, false])
    }

    func testTheAppsMuteReachesTheScreenOnce() {
        startAPlacedCall()

        host.muted = true
        calls.followOnce()
        calls.followOnce()

        XCTAssertEqual(kit.mutedReports, [true])
        XCTAssertEqual(host.mutedValues, [], "the mute was the app's: it isn't set back")
    }

    func testACallPlacedMutedSaysSoOnTheScreen() {
        host.muted = true

        startAPlacedCall()

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

// MARK: - Seams

@MainActor
private final class FakePlacedCallKit: VoicePlacedCallKit {
    var isAvailable = true
    var placeResult = true
    private(set) var names: [String] = []
    private(set) var endRequests = 0
    private(set) var mutedReports: [Bool] = []
    var onPlacedCallStarted: (@MainActor () -> Void)?
    var onPlacedCallEnded: (@MainActor (Bool) -> Void)?
    var onPlacedCallMuteChanged: (@MainActor (Bool) -> Void)?

    func placeCall(named name: String) -> Bool {
        names.append(name)
        return placeResult
    }

    func requestPlacedCallEnd() {
        endRequests += 1
    }

    func reportPlacedCallMuted(_ muted: Bool) {
        mutedReports.append(muted)
    }
}

/// The app's side of a placed call, and what the call did to it.
@MainActor
private final class FakePlacedCallHost {
    var isSettingOn = true
    var running = true
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
            endVoice: { @MainActor in self.endVoiceCount += 1 },
            voiceMuted: { @MainActor in self.muted },
            setVoiceMuted: { @MainActor muted in
                self.muted = muted
                self.mutedValues.append(muted)
            },
            setCallActive: { @MainActor active in self.callActiveValues.append(active) }
        )
    }
}

/// Records what the coordinator asked of the session, without touching the
/// process-global AVAudioSession.
private final class PlacedCallAudioSession: VoiceAudioSessionControlling {
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
