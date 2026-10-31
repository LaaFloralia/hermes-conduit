#if LAA_BUILD
//
//  LAAChatAudioSessionTests.swift
//  ConduitTests
//
//  BUS-332: opening a conversation must not stop the music another app is
//  playing. The chat's idle policy is checked against a fake session (never
//  the process-global AVAudioSession), and the call's own switch and release
//  are checked against the existing voice coordinator with another fake, so
//  the two owners stay distinct: the chat only mixes, the call only takes.
//

import AVFAudio
import XCTest
@testable import Conduit

@MainActor
final class LAAChatAudioSessionTests: XCTestCase {
    func testOpeningAConversationOnlyAsksForMixing() {
        let session = FakeChatAudioSession()
        let audio = LAAChatAudioSession(session: session, voiceState: { .idle })

        audio.chatShown()

        XCTAssertEqual(session.events, [
            .category(.init(category: .ambient, mode: .default, options: [.mixWithOthers]))
        ])
        XCTAssertEqual(session.category, .ambient)
        XCTAssertNotEqual(session.category, .playback, "playback would silence the user's music")
        XCTAssertNotEqual(session.category, .playAndRecord, "a display-only chat is not a call")
        XCTAssertTrue(session.activations.isEmpty, "the idle chat never activates the session")
    }

    func testTheIdleVideoMixesWhileTheSessionIsAlreadyActive() {
        // A media playback that already activated the session: the chat still
        // only makes it mixable, and never touches its activation.
        let session = FakeChatAudioSession()
        session.isActive = true
        let audio = LAAChatAudioSession(session: session, voiceState: { .idle })

        audio.chatShown()

        XCTAssertEqual(session.category, .ambient)
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
        XCTAssertTrue(session.activeChanges.isEmpty)
        XCTAssertTrue(session.isActive, "the idle policy leaves the session's state alone")
    }

    func testMixingIsAppliedOnceWhileTheConversationStaysOpen() {
        let session = FakeChatAudioSession()
        let audio = LAAChatAudioSession(session: session, voiceState: { .idle })

        audio.chatShown()
        audio.chatShown()

        XCTAssertEqual(session.categoryChanges.count, 1)
        XCTAssertTrue(session.activeChanges.isEmpty)
    }

    func testARunningCallKeepsTheVoiceCoordinatorsCategory() {
        let session = FakeChatAudioSession()
        session.category = .playAndRecord
        session.categoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
        session.isActive = true
        let audio = LAAChatAudioSession(session: session, voiceState: { .conversation })

        audio.chatShown()

        XCTAssertTrue(session.events.isEmpty, "the call's category, options and activation are its own")
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertTrue(session.isActive)
    }

    func testACallIsPlacedByTheVoiceCoordinatorAndReleasedWithNotifyOthers() throws {
        // The call side is unchanged: the existing coordinator switches to the
        // call's category when it takes the session, and hands it back with
        // `.notifyOthersOnDeactivation` when its last owner releases.
        let session = FakeVoiceAudioSession()
        let coordinator = VoiceAudioSessionCoordinator(session: session)

        let lease = try coordinator.acquire(.conversationCapture)

        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertEqual(session.mode, .voiceChat)
        XCTAssertEqual(session.activeChanges.map { $0.active }, [true])

        coordinator.release(lease)

        XCTAssertNil(coordinator.appliedPolicy)
        XCTAssertEqual(session.activeChanges.map { $0.active }, [true, false])
        XCTAssertEqual(session.activeChanges.last?.options, AVAudioSession.SetActiveOptions.notifyOthersOnDeactivation)
    }

    func testTheEndOfACallRestoresMixingAndReleasesTheSession() {
        let session = FakeChatAudioSession()
        session.category = .playAndRecord
        session.categoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
        session.isActive = true
        let audio = LAAChatAudioSession(session: session, voiceState: { .idle })

        audio.voiceEnded()

        XCTAssertEqual(session.events, [
            .category(.init(category: .ambient, mode: .default, options: [.mixWithOthers])),
            .active(false, .notifyOthersOnDeactivation)
        ])
    }

    func testACallStillWindingDownOnlyGetsItsCategoryBack() {
        // The coordinator has not released its lease yet: it does the
        // deactivation itself, so the chat must not pull the session out from
        // under the call's teardown.
        let session = FakeChatAudioSession()
        session.category = .playAndRecord
        session.isActive = true
        let audio = LAAChatAudioSession(session: session, voiceState: { .conversation })

        audio.voiceEnded()

        XCTAssertEqual(session.events, [
            .category(.init(category: .ambient, mode: .default, options: [.mixWithOthers]))
        ])
        XCTAssertTrue(session.isActive)
    }

    func testANativeCallEndingLeavesTheSessionToCallKit() {
        let session = FakeChatAudioSession()
        session.category = .playAndRecord
        session.isActive = true
        let audio = LAAChatAudioSession(
            session: session,
            voiceState: { LAAChatAudioVoiceState(holdsSession: true, nativeCall: true) }
        )

        audio.voiceEnded()

        XCTAssertTrue(session.events.isEmpty, "CallKit deactivates its own call audio")
        XCTAssertTrue(session.isActive)
    }
}

private struct FakeCategoryChange: Equatable {
    var category: AVAudioSession.Category
    var mode: AVAudioSession.Mode
    var options: AVAudioSession.CategoryOptions
}

@MainActor
private final class FakeChatAudioSession: LAAChatAudioSessionControlling {
    enum Event: Equatable {
        case category(FakeCategoryChange)
        case active(Bool, AVAudioSession.SetActiveOptions)
    }

    var category: AVAudioSession.Category = .soloAmbient
    var categoryOptions: AVAudioSession.CategoryOptions = []
    /// Mirrors what the session would hold; the protocol cannot read it.
    var isActive = false
    private(set) var events: [Event] = []

    var categoryChanges: [FakeCategoryChange] {
        events.compactMap { if case .category(let change) = $0 { change } else { nil } }
    }
    var activeChanges: [(active: Bool, options: AVAudioSession.SetActiveOptions)] {
        events.compactMap {
            if case .active(let active, let options) = $0 { (active: active, options: options) } else { nil }
        }
    }
    var activations: [AVAudioSession.SetActiveOptions] {
        activeChanges.filter { $0.active }.map { $0.options }
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        self.category = category
        categoryOptions = options
        events.append(.category(FakeCategoryChange(category: category, mode: mode, options: options)))
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        isActive = active
        events.append(.active(active, options))
    }
}

/// Only what the voice coordinator's policy touches; the route helpers keep
/// their protocol defaults.
@MainActor
private final class FakeVoiceAudioSession: VoiceAudioSessionControlling {
    private(set) var category: AVAudioSession.Category = .soloAmbient
    private(set) var mode: AVAudioSession.Mode = .default
    private(set) var activeChanges: [(active: Bool, options: AVAudioSession.SetActiveOptions)] = []
    var isOtherAudioPlaying = false

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        self.category = category
        self.mode = mode
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        activeChanges.append((active: active, options: options))
    }
}
#endif
