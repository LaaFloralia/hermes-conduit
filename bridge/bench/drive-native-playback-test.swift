import AVFoundation
import Combine
import Foundation

private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw FixtureFailure(message) }
}

@MainActor
private func waitFor(_ message: String, timeout: TimeInterval = 6,
                     _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { throw FixtureFailure("timed out: \(message)") }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

@main
struct NativePlaybackFixture {
    @MainActor
    static func main() async throws {
        let movie = URL(fileURLWithPath: CommandLine.arguments[1])
        let suite = "laa.fixture.playback.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite),
              let identity = LAADrivePlaybackIdentity(pairingID: "fake-pairing", contentID: "fake-video", version: "1") else {
            throw FixtureFailure("fixture setup failed")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LAADriveResumeStore(defaults: defaults)
        let player = AVPlayer()
        player.isMuted = true
        var opens = 0
        var closes = 0
        var acquires = 0
        var releases = 0
        let coordinator = LAADrivePlaybackCoordinator(
            player: player, identity: identity, resumeStore: store, startsBufferedPlayback: true,
            openSource: { opens += 1; player.replaceCurrentItem(with: AVPlayerItem(url: movie)) },
            closeSource: { closes += 1; player.replaceCurrentItem(with: nil) },
            acquireAudio: { acquires += 1 }, releaseAudio: { releases += 1 })
        var seen: [LAADrivePlaybackState] = []
        let subscription = coordinator.$state.sink { seen.append($0) }

        coordinator.start(autoPlay: false)
        try await waitFor("initial paused: \(coordinator.state)") { coordinator.state == .paused }
        try check(player.rate == 0 && acquires == 0 && opens == 1, "autoplay false played or acquired audio")
        coordinator.start(autoPlay: true)
        try check(opens == 1, "second start reopened the source")
        coordinator.play()
        try await waitFor("play: \(coordinator.state)") { coordinator.state == .playing }
        try await Task.sleep(nanoseconds: 350_000_000)
        player.pause() // Native controls can operate on AVPlayer directly.
        try await waitFor("native pause: \(coordinator.state)") { coordinator.state == .paused }
        try await Task.sleep(for: .milliseconds(200))
        try check(player.rate == 0 && coordinator.state == .paused, "buffer observations resumed an explicit native pause")
        try check(releases > 0, "pausing did not release audio")
        try check((store.position(for: identity) ?? 0) > 0, "native pause did not save position")
        player.play()
        try await waitFor("native play: \(coordinator.state)") { coordinator.state == .playing }
        try await waitFor("end: \(coordinator.state)") { coordinator.state == .ended }
        try check(store.position(for: identity) == nil, "end did not clear resume position")
        coordinator.replay()
        try await waitFor("replay: \(coordinator.state)") { coordinator.state == .playing }
        try check(player.currentTime().seconds < 1, "replay did not seek to the start")
        coordinator.reportFailure("fixture error")
        try check(coordinator.state == .failed("fixture error") && player.rate == 0,
                  "failure did not pause and expose its message")
        coordinator.retry()
        try await waitFor("retry autoplay: \(coordinator.state)") { coordinator.state == .playing }
        try check(opens == 2 && closes == 1, "retry did not reopen the source")
        coordinator.stop()
        try check(opens == 2 && closes == 2 && player.currentItem == nil, "stop did not close the source")
        try check(acquires == releases, "audio ownership leaked: \(acquires) acquired, \(releases) released")
        try check(player.isMuted, "stop did not preserve the caller's mute setting")
        try check(seen.contains(.loading) && seen.contains(.paused) && seen.contains(.playing)
                  && seen.contains(.ended) && seen.contains(.failed("fixture error")), "a state was not published")
        withExtendedLifetime(subscription) {}

        store.save(0.8, for: identity)
        let resumedPlayer = AVPlayer()
        resumedPlayer.isMuted = true
        var resumeAcquires = 0
        let resumed = LAADrivePlaybackCoordinator(
            player: resumedPlayer, identity: identity, resumeStore: store,
            openSource: { resumedPlayer.replaceCurrentItem(with: AVPlayerItem(url: movie)) },
            closeSource: { resumedPlayer.replaceCurrentItem(with: nil) },
            acquireAudio: { resumeAcquires += 1 }, releaseAudio: {})
        resumed.start(autoPlay: false)
        try await waitFor("resume paused: \(resumed.state)") { resumed.state == .paused }
        try check(abs(resumedPlayer.currentTime().seconds - 0.8) < 0.2, "resume did not seek to saved position")
        try check(resumeAcquires == 0 && resumedPlayer.rate == 0, "resume autoplayed")
        resumed.stop()

        store.save(0.8, for: identity)
        let earlyPlayer = AVPlayer()
        var acquiredWhileMuted = false
        let early = LAADrivePlaybackCoordinator(
            player: earlyPlayer, identity: identity, resumeStore: store,
            openSource: { earlyPlayer.replaceCurrentItem(with: AVPlayerItem(url: movie)) },
            closeSource: { earlyPlayer.replaceCurrentItem(with: nil) },
            acquireAudio: { acquiredWhileMuted = earlyPlayer.isMuted }, releaseAudio: {})
        early.start(autoPlay: false)
        earlyPlayer.play() // Native controls may be pressed before the item is ready.
        try await waitFor("early native play after resume: \(early.state)") { early.state == .playing }
        try check(earlyPlayer.currentTime().seconds >= 0.6, "early play skipped the saved position")
        try check(acquiredWhileMuted && !earlyPlayer.isMuted, "audio was not gated before ownership")
        early.stop()
        try check(!earlyPlayer.isMuted, "stop did not restore the caller's unmuted setting")

        let failurePlayer = AVPlayer()
        failurePlayer.isMuted = true
        var sourceExists = false
        let sourceFailure = LAADrivePlaybackCoordinator(
            player: failurePlayer, identity: nil,
            openSource: { failurePlayer.replaceCurrentItem(with: AVPlayerItem(url: sourceExists ? movie : URL(fileURLWithPath: "/nonexistent-laa-fixture.mov"))) },
            closeSource: { failurePlayer.replaceCurrentItem(with: nil) },
            acquireAudio: {}, releaseAudio: {})
        sourceFailure.start(autoPlay: false)
        try await waitFor("missing source failure: \(sourceFailure.state)") {
            if case .failed = sourceFailure.state { return true }; return false
        }
        sourceExists = true
        sourceFailure.retry()
        try await waitFor("retry after source failure: \(sourceFailure.state)") { sourceFailure.state == .playing }
        sourceFailure.stop()

        let deniedPlayer = AVPlayer()
        let denied = LAADrivePlaybackCoordinator(
            player: deniedPlayer, identity: nil, audioFailureMessage: "audio denied",
            openSource: { deniedPlayer.replaceCurrentItem(with: AVPlayerItem(url: movie)) },
            closeSource: { deniedPlayer.replaceCurrentItem(with: nil) },
            acquireAudio: { throw FixtureFailure("denied") }, releaseAudio: {})
        denied.start(autoPlay: false)
        try await waitFor("audio test ready: \(denied.state)") { denied.state == .paused }
        try check(deniedPlayer.isMuted, "paused player is not gated")
        denied.play()
        try check(denied.state == .failed("audio denied") && deniedPlayer.rate == 0,
                  "denied audio did not prevent requested playback")
        try check(deniedPlayer.isMuted, "denied playback was audible")
        denied.stop()
        try check(!deniedPlayer.isMuted, "stop left the player muted")
        denied.start(autoPlay: false)
        try await waitFor("audio test ready after stop: \(denied.state)") { denied.state == .paused }
        deniedPlayer.play()
        try await waitFor("native play denied: \(denied.state)") { denied.state == .failed("audio denied") }
        try check(deniedPlayer.rate == 0 && deniedPlayer.isMuted, "denied native playback was not stopped and muted")
        denied.stop()
        print("native playback fixture passed")
    }
}
