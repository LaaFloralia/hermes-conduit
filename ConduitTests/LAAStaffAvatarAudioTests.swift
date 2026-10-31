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
//  still plays. Older versions cannot, so the avatar keeps its still while
//  another app is playing. Both branches are decided by
//  `StaffAvatarIdleAudioPolicy`, away from the session and the view.
//

import XCTest
@testable import Conduit

final class LAAStaffAvatarAudioTests: XCTestCase {
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
}
#endif
