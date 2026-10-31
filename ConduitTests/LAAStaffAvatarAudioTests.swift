#if LAA_BUILD
//
//  LAAStaffAvatarAudioTests.swift
//  ConduitTests
//
//  BUS-332: the idle avatar video must not stop another app's music. An
//  AVPlayer connected to system audio activates the shared session as soon as
//  it plays, and the app's category is the non-mixable default.
//
//  iOS 27 and later can disconnect the player from system audio, so the video
//  still plays; older versions cannot, so the avatar keeps its still while
//  another app is playing. Both branches are decided by
//  `StaffAvatarIdleAudioPolicy`, away from the session and the view. The
//  start order is fixed with a fake disconnect: nothing may play before the
//  player has left system audio, even if the avatar starts again meanwhile.
//

import AVFoundation
import os
import XCTest
@testable import Conduit

@MainActor
final class LAAStaffAvatarAudioTests: XCTestCase {
    // MARK: - The idle audio decision

    func testIOS27DisconnectsThePlayerAndKeepsTheVideoUnderOtherAudio() {
        let policy = StaffAvatarIdleAudioPolicy(shouldPlay: true,
                                                canDisconnectFromSystemAudio: true,
                                                otherAudioPlaying: true)

        XCTAssertTrue(policy.startsVideo, "a disconnected player needs no session, so the video may run")
        XCTAssertTrue(policy.disconnectsFromSystemAudio)
    }

    func testAnOlderIOSKeepsTheStillWhileAnotherAppPlays() {
        let policy = StaffAvatarIdleAudioPolicy(shouldPlay: true,
                                                canDisconnectFromSystemAudio: false,
                                                otherAudioPlaying: true)

        XCTAssertFalse(policy.startsVideo, "playing would activate the session and stop the other app")
        XCTAssertFalse(policy.disconnectsFromSystemAudio)
    }

    func testAnOlderIOSPlaysWhenNothingElseIsPlaying() {
        let policy = StaffAvatarIdleAudioPolicy(shouldPlay: true,
                                                canDisconnectFromSystemAudio: false,
                                                otherAudioPlaying: false)

        XCTAssertTrue(policy.startsVideo)
        XCTAssertFalse(policy.disconnectsFromSystemAudio)
    }

    func testIOS27LeavesTheSessionAloneEvenWhenNothingElseIsPlaying() {
        let policy = StaffAvatarIdleAudioPolicy(shouldPlay: true,
                                                canDisconnectFromSystemAudio: true,
                                                otherAudioPlaying: false)

        XCTAssertTrue(policy.startsVideo)
        XCTAssertTrue(policy.disconnectsFromSystemAudio, "the player is always disconnected where it can be")
    }

    func testTheAvatarsExistingPlaybackDecisionStillStopsTheVideo() {
        for canDisconnect in [true, false] {
            for otherAudio in [true, false] {
                let policy = StaffAvatarIdleAudioPolicy(shouldPlay: false,
                                                        canDisconnectFromSystemAudio: canDisconnect,
                                                        otherAudioPlaying: otherAudio)
                XCTAssertFalse(policy.startsVideo,
                               "hidden, inactive, Reduce Motion, Low Power or scrolling keeps the still")
            }
        }
    }

    // MARK: - The start order

    func testTheVideoWaitsForTheDisconnectBeforeItPlays() async {
        let player = RecordingQueuePlayer()
        var releases: [CheckedContinuation<Void, Never>] = []
        let loop = StaffAvatarLoop(
            makePlayer: { player },
            makeLooper: { _, _ in nil },
            disconnect: { _ in
                await withCheckedContinuation { continuation in releases.append(continuation) }
            }
        )
        let url = URL(fileURLWithPath: "/tmp/idle.mov")

        loop.play(url, disconnectingFromSystemAudio: true)
        XCTAssertEqual(player.playCount, 0, "a connected player would activate the session")
        await waitUntil { releases.count == 1 }

        // The avatar starts again before the disconnect completes (onAppear,
        // scenePhase or scrolling): still nothing may play, and the second
        // start must not queue another disconnect.
        loop.play(url, disconnectingFromSystemAudio: true)
        XCTAssertEqual(player.playCount, 0)
        XCTAssertEqual(releases.count, 1)

        releases[0].resume()
        await waitUntil { player.playCount == 1 }
        XCTAssertEqual(player.playCount, 1)

        // Already disconnected: a later start resumes at once.
        loop.play(url, disconnectingFromSystemAudio: true)
        XCTAssertEqual(player.playCount, 2)
        XCTAssertEqual(releases.count, 1)
    }

    func testACompletionAfterStopDoesNotStartPlayback() async {
        let player = RecordingQueuePlayer()
        var releases: [CheckedContinuation<Void, Never>] = []
        let loop = StaffAvatarLoop(
            makePlayer: { player },
            makeLooper: { _, _ in nil },
            disconnect: { _ in
                await withCheckedContinuation { continuation in releases.append(continuation) }
            }
        )
        let url = URL(fileURLWithPath: "/tmp/idle.mov")

        loop.play(url, disconnectingFromSystemAudio: true)
        await waitUntil { releases.count == 1 }
        loop.stop()
        releases[0].resume()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(player.playCount, 0, "the avatar moved on; a late disconnect must not play")
        XCTAssertEqual(player.pauseCount, 1)
    }

    func testWithoutTheDisconnectItPlaysAtOnce() {
        let player = RecordingQueuePlayer()
        let loop = StaffAvatarLoop(
            makePlayer: { player },
            makeLooper: { _, _ in nil },
            disconnect: { _ in XCTFail("this start must not wait for a disconnect") }
        )

        loop.play(URL(fileURLWithPath: "/tmp/idle.mov"), disconnectingFromSystemAudio: false)

        XCTAssertEqual(player.playCount, 1)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met", file: file, line: line)
    }
}

/// Records the loop's playback calls; the real player would start AVFoundation
/// work this test does not need. The counts are lock-protected because the
/// player's own play/pause methods are not main-actor isolated.
private final class RecordingQueuePlayer: AVQueuePlayer, @unchecked Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (plays: 0, pauses: 0))

    var playCount: Int { counts.withLock { $0.plays } }
    var pauseCount: Int { counts.withLock { $0.pauses } }

    override func play() { counts.withLock { $0.plays += 1 } }
    override func pause() { counts.withLock { $0.pauses += 1 } }
}
#endif
