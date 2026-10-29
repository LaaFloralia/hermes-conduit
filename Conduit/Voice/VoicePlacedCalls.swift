//
//  VoicePlacedCalls.swift
//  Conduit
//
//  A call the user starts in Conduit, placed as a phone call (LAA fork):
//  the voice conversation is reported to CallKit as an outgoing call, so
//  iOS's own call screen runs it — "Calling…" then connected, the lock
//  screen, the Dynamic Island, the call banner over other apps, the
//  earpiece, and the screen going off against the ear. CallKit's Mute and
//  End drive the conversation, and the conversation's own end, a failed
//  engine or a sign-out hang the CallKit call up, so the two never
//  disagree.
//
//  "Place calls as phone calls" (VoicePhoneCalls) is on by default in this
//  build. Where CallKit can't be used (a build without it, China's App
//  Store, a call from Hermes already on the screen) the conversation still
//  plays like a phone call on the earpiece, with the call screen's own
//  Speaker button and the proximity sensor: that is what the setting did
//  before this build placed the call, and it is the fallback here.
//
//  CallKit itself is HermesNativeCalls' one CXProvider (it already runs
//  calls from Hermes); this file is the half that follows the conversation.
//

import Foundation
import OSLog
import SwiftUI

private let placedCallsLogger = Logger(subsystem: "com.milim.relay", category: "VoiceCalls")

/// What placing the user's own call needs from CallKit. `HermesNativeCalls`
/// implements it on the provider it already has; tests substitute a fake.
@MainActor
protocol VoicePlacedCallKit: AnyObject {
    /// CallKit may be used here: this build, this storefront, and not a run
    /// of the test host.
    var isAvailable: Bool { get }
    /// Asks CallKit to place a call that shows `name` on the system's call
    /// screen. False when it couldn't even ask.
    func placeCall(named name: String) -> Bool
    /// Asks CallKit to end the call it shows.
    func requestPlacedCallEnd()
    /// Shows this phone's mute on the system's call screen.
    func reportPlacedCallMuted(_ muted: Bool)
    /// CallKit performed the start: the call is on the system's screen.
    var onPlacedCallStarted: (@MainActor () -> Void)? { get set }
    /// CallKit's call is over, or was never shown. `bySystem` is true when
    /// Conduit didn't ask for it (the screen's End, a CallKit reset).
    var onPlacedCallEnded: (@MainActor (_ bySystem: Bool) -> Void)? { get set }
    /// The system's call screen muted or unmuted the call.
    var onPlacedCallMuteChanged: (@MainActor (Bool) -> Void)? { get set }
}

/// What a placed call needs from the app, injected so the state machine
/// can be asserted without an AppState or CallKit. Every closure runs on
/// the main actor, where the call and AppState live.
struct VoicePlacedCallHost {
    var isSettingOn: @MainActor () -> Bool
    /// A voice conversation the user started on this phone is running.
    var isVoiceRunning: @MainActor () -> Bool
    /// Who the system's call screen says is being called.
    var displayName: @MainActor () -> String
    /// Ends the conversation it carries, as the app's End does.
    var endVoice: @MainActor () -> Void
    /// The conversation's own mute, nil while no voice holds it.
    var voiceMuted: @MainActor () -> Bool?
    var setVoiceMuted: @MainActor (Bool) -> Void
    /// The call is on the system's screen (or no longer is): the voice it
    /// carries keeps running with the phone locked or another app in front.
    var setCallActive: @MainActor (Bool) -> Void
}

extension VoicePlacedCallHost {
    /// The running app, read when a call needs it: the phone's own
    /// conversation, not one CarPlay or the Watch runs.
    @MainActor
    static var appState: VoicePlacedCallHost {
        VoicePlacedCallHost(
            isSettingOn: { VoicePhoneCalls.isOn },
            isVoiceRunning: { AppStateRuntimeRegistry.shared.existing?.isPhoneVoiceCallRunning ?? false },
            displayName: { AppStateRuntimeRegistry.shared.existing?.placedCallName ?? HermesCallerName.fallback },
            endVoice: { AppStateRuntimeRegistry.shared.existing?.endVoiceForPlacedCall() },
            voiceMuted: { AppStateRuntimeRegistry.shared.existing?.nativeCallVoiceMuted },
            setVoiceMuted: { AppStateRuntimeRegistry.shared.existing?.setVoiceMutedForNativeCall($0) },
            setCallActive: { AppStateRuntimeRegistry.shared.existing?.setPlacedPhoneCallActive($0) }
        )
    }
}

/// One call at a time, from the conversation's first turn to its end: the
/// system's call screen follows the voice, and the voice follows the call.
@MainActor
final class VoicePlacedCalls {
    static let shared = VoicePlacedCalls()

    enum Phase: Equatable {
        case idle
        /// Asked for; CallKit hasn't shown the call yet.
        case placing
        /// On the system's call screen.
        case running
        /// Asked to end; waiting for CallKit to perform the end.
        case ending
    }

    /// How often a running call re-reads the conversation: a mute made in
    /// the app reaches the system's screen, and a conversation that ended
    /// without the views seeing it still hangs the call up.
    static let followInterval: Duration = .milliseconds(500)

    private(set) var phase: Phase = .idle
    /// The call's mute as last told to CallKit, so only a change is sent.
    private(set) var reportedMuted: Bool?

    private let callKit: VoicePlacedCallKit
    private let audio: VoiceAudioSessionCoordinator
    private let host: VoicePlacedCallHost
    private var followTask: Task<Void, Never>?

    /// `callKit` and `audio` default inside the body: `.shared` of a
    /// MainActor type can't be read from a default argument.
    init(
        callKit: VoicePlacedCallKit? = nil,
        audio: VoiceAudioSessionCoordinator? = nil,
        host: VoicePlacedCallHost? = nil
    ) {
        let callKit = callKit ?? HermesNativeCalls.shared
        self.callKit = callKit
        self.audio = audio ?? .shared
        self.host = host ?? .appState
        callKit.onPlacedCallStarted = { [weak self] in self?.started() }
        callKit.onPlacedCallEnded = { [weak self] bySystem in self?.ended(bySystem: bySystem) }
        callKit.onPlacedCallMuteChanged = { [weak self] muted in self?.muteChanged(muted) }
    }

    /// The phone's voice conversation started or ended. The root view calls
    /// this as it changes; a call in progress re-checks on its own too.
    func voiceChanged(running: Bool) {
        if running {
            placeIfWanted()
        } else {
            endFromApp()
        }
    }

    /// Places the call when the setting asks for it and nothing else has the
    /// system's call screen. Otherwise the conversation carries on as it
    /// played before: on the earpiece, with the app's own controls.
    private func placeIfWanted() {
        guard phase == .idle, host.isSettingOn(), callKit.isAvailable else { return }
        // A call from Hermes already has the system's call screen: one call
        // group, and the conversation that call opened is its own.
        guard !audio.isInNativeCall else { return }
        // The view's change and the call can cross: never place one for a
        // conversation that has already ended.
        guard host.isVoiceRunning() else { return }
        let name = host.displayName()
        guard callKit.placeCall(named: name) else {
            placedCallsLogger.info("no call placed: CallKit refused the request")
            return
        }
        phase = .placing
        follow()
    }

    /// CallKit performed the start: the call is on the system's screen. The
    /// coordinator enters the call's session policy here, before CallKit
    /// activates the audio, so a conversation holding the session moves onto
    /// it and the call's own audio is kept.
    private func started() {
        guard phase == .placing else { return }
        phase = .running
        audio.configureForNativeCall()
        host.setCallActive(true)
        reportedMuted = host.voiceMuted() ?? false
        if reportedMuted == true {
            // The conversation was already muted (a paused microphone):
            // the system's screen says so too.
            callKit.reportPlacedCallMuted(true)
        }
    }

    /// The conversation ended in the app: CallKit hangs its call up.
    private func endFromApp() {
        switch phase {
        case .idle, .ending:
            return
        case .placing, .running:
            phase = .ending
            callKit.requestPlacedCallEnd()
        }
    }

    /// CallKit's call is gone: its screen's End, a reset, an end asked for
    /// here, or a request CallKit refused. The conversation it carried ends
    /// only when the user ended the call, never when Conduit was the one
    /// hanging up (or the call never was on screen).
    private func ended(bySystem: Bool) {
        guard phase != .idle else { return }
        // A call CallKit never showed carries nothing: the conversation
        // that asked for it keeps running as it did before.
        let wasOnScreen = phase != .placing
        phase = .idle
        stopFollowing()
        reportedMuted = nil
        // The conversation ends first, as a call from Hermes does: it lets
        // the session go while CallKit still owns it, and only then does the
        // coordinator leave the call's policy.
        if bySystem, wasOnScreen { host.endVoice() }
        audio.nativeCallEnded()
        if wasOnScreen { host.setCallActive(false) }
    }

    /// The system's call screen muted or unmuted the call.
    private func muteChanged(_ muted: Bool) {
        guard phase == .running || phase == .placing else { return }
        reportedMuted = muted
        host.setVoiceMuted(muted)
    }

    /// Re-reads the conversation while the call is up. Called by the loop
    /// below every `followInterval`, and directly by the tests.
    func followOnce() {
        guard phase == .running || phase == .placing else { return }
        if let muted = host.voiceMuted(), muted != reportedMuted {
            reportedMuted = muted
            callKit.reportPlacedCallMuted(muted)
        }
        if !host.isVoiceRunning() { endFromApp() }
    }

    private func follow() {
        stopFollowing()
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.followInterval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.followOnce()
            }
        }
    }

    private func stopFollowing() {
        followTask?.cancel()
        followTask = nil
    }
}

/// Keeps the CallKit call in step with the phone's voice conversation. The
/// root view carries it, as it carries the earpiece call's proximity
/// sensor: the conversation outlives neither the app nor this view.
struct PlacedCallBridge: ViewModifier {
    @EnvironmentObject private var appState: AppState

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.isPhoneVoiceCallRunning, initial: true) { _, running in
                VoicePlacedCalls.shared.voiceChanged(running: running)
            }
            // Sign-out swaps this view out with a call possibly still up,
            // and ends it without this view seeing the conversation end.
            .onDisappear { VoicePlacedCalls.shared.voiceChanged(running: false) }
    }
}
