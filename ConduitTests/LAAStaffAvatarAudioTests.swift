#if LAA_BUILD
//
//  LAAStaffAvatarAudioTests.swift
//  ConduitTests
//
//  BUS-332: the idle avatar video must not stop another app's music. An
//  AVPlayer connected to system audio activates the shared session as soon as
//  it plays, and the app's category is the non-mixable default. The video
//  therefore runs only where the player can leave system audio first
//  (iOS 27+); everywhere else the avatar keeps its still. The start order is
//  fixed with a fake disconnect: nothing may play before the player has left
//  system audio, whatever order the completions arrive in.
//

import AVFoundation
import os
import XCTest
@testable import Conduit

@MainActor
final class LAAStaffAvatarAudioTests: XCTestCase {
    // MARK: - The idle audio decision

    func testIOS27PlaysTheVideoOnlyWhereItCanDisconnect() {
        let policy = StaffAvatarIdleAudioPolicy(shouldPlay: true, canDisconnectFromSystemAudio: true)

        XCTAssertTrue(policy.startsVideo, "the player leaves system audio, so the video may run")
    }

    func testAVersionThatCannotDisconnectKeepsTheStill() {
        // iOS 17–26, and Mac Catalyst, where the disconnect API is unavailable:
        // a connected player could stop another app's audio, so no video.
        let policy = StaffAvatarIdleAudioPolicy(shouldPlay: true, canDisconnectFromSystemAudio: false)

        XCTAssertFalse(policy.startsVideo)
    }

    func testTheAvatarsExistingPlaybackDecisionStillStopsTheVideo() {
        for canDisconnect in [true, false] {
            let policy = StaffAvatarIdleAudioPolicy(shouldPlay: false, canDisconnectFromSystemAudio: canDisconnect)
            XCTAssertFalse(policy.startsVideo,
                           "hidden, inactive, Reduce Motion, Low Power or scrolling keeps the still")
        }
    }

    // MARK: - The start order

    func testTheVideoWaitsForTheDisconnectBeforeItPlays() async {
        let player = RecordingQueuePlayer()
        let releases = ContinuationBox()
        let loop = makeLoop(players: [player], releases: releases)
        let url = URL(fileURLWithPath: "/tmp/idle.mov")

        loop.play(url)
        XCTAssertEqual(player.playCount, 0, "a connected player would activate the session")
        await waitUntil { releases.items.count == 1 }

        // The avatar starts again before the disconnect completes (onAppear,
        // scenePhase or scrolling): still nothing may play, and the second
        // start must not queue another disconnect.
        loop.play(url)
        XCTAssertEqual(player.playCount, 0)
        XCTAssertEqual(releases.items.count, 1)

        releases.items[0].resume()
        await waitUntil { player.playCount == 1 }
        XCTAssertEqual(player.playCount, 1)

        // Already disconnected: a later start resumes at once.
        loop.play(url)
        XCTAssertEqual(player.playCount, 2)
        XCTAssertEqual(releases.items.count, 1)
    }

    func testACompletionAfterStopDoesNotStartPlayback() async {
        let player = RecordingQueuePlayer()
        let releases = ContinuationBox()
        let loop = makeLoop(players: [player], releases: releases)
        let url = URL(fileURLWithPath: "/tmp/idle.mov")

        loop.play(url)
        await waitUntil { releases.items.count == 1 }
        loop.stop()
        releases.items[0].resume()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(player.playCount, 0, "the avatar moved on; a late disconnect must not play")
        XCTAssertEqual(player.pauseCount, 1)
    }

    func testSwitchingToAnotherVideoIgnoresTheOldDisconnect() async {
        let first = RecordingQueuePlayer()
        let second = RecordingQueuePlayer()
        let releases = ContinuationBox()
        let loop = makeLoop(players: [first, second], releases: releases)
        let a = URL(fileURLWithPath: "/tmp/a.mov")
        let b = URL(fileURLWithPath: "/tmp/b.mov")

        loop.play(a)
        await waitUntil { releases.items.count == 1 }
        loop.play(b)
        await waitUntil { releases.items.count == 2 }

        // Out of order: A's disconnect arrives after B started waiting.
        releases.items[0].resume()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(first.playCount, 0, "a stale completion must not start the old player")
        XCTAssertEqual(second.playCount, 0, "B still waits for its own disconnect")
        XCTAssertEqual(first.pauseCount, 1, "the switch stopped A")

        releases.items[1].resume()
        await waitUntil { second.playCount == 1 }
        XCTAssertEqual(second.playCount, 1)
        XCTAssertEqual(first.playCount, 0)
    }

    func testRestartingTheSameVideoAfterStopWaitsForItsOwnDisconnect() async {
        let first = RecordingQueuePlayer()
        let second = RecordingQueuePlayer()
        let releases = ContinuationBox()
        let loop = makeLoop(players: [first, second], releases: releases)
        let url = URL(fileURLWithPath: "/tmp/idle.mov")

        loop.play(url)
        await waitUntil { releases.items.count == 1 }
        loop.stop()
        loop.play(url)
        await waitUntil { releases.items.count == 2 }

        // The stopped player's completion is stale even though the URL matches.
        releases.items[0].resume()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(first.playCount, 0)
        XCTAssertEqual(second.playCount, 0)

        releases.items[1].resume()
        await waitUntil { second.playCount == 1 }
        XCTAssertEqual(second.playCount, 1)
        XCTAssertEqual(first.playCount, 0)
    }

    // MARK: - Helpers

    private func makeLoop(players: [RecordingQueuePlayer], releases: ContinuationBox) -> StaffAvatarLoop {
        var remaining = players
        return StaffAvatarLoop(
            makePlayer: { remaining.removeFirst() },
            makeLooper: { _, _ in nil },
            disconnect: { _ in
                await withCheckedContinuation { continuation in releases.items.append(continuation) }
            }
        )
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

/// Holds the disconnect completions a test releases by hand.
@MainActor
private final class ContinuationBox {
    var items: [CheckedContinuation<Void, Never>] = []
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
