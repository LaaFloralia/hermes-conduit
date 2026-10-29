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
//  The call is placed before the conversation's audio starts, and the
//  conversation opens only once CallKit has activated the call's audio
//  (`didActivate`), so no engine starts on a session CallKit is about to
//  take. Phone launches, including a widget, a saved call, or a mode switch,
//  wait for that activation before starting a new conversation.
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
    /// Asks CallKit to end the call it shows. Its failure paths (a call
    /// CallKit no longer has, a request it keeps refusing) are handled
    /// behind it: the end still comes back through `onPlacedCallEnded`.
    func requestPlacedCallEnd()
    /// Shows this phone's mute on the system's call screen. `result` says
    /// whether CallKit took it, so a refused mute is sent again.
    func reportPlacedCallMuted(_ muted: Bool, result: @escaping @MainActor (Bool) -> Void)
    /// CallKit performed the start: the call is on the system's screen.
    var onPlacedCallStarted: (@MainActor () -> Void)? { get set }
    /// CallKit activated the call's audio (`didActivate`), after the start.
    var onPlacedCallAudioActivated: (@MainActor () -> Void)? { get set }
    /// CallKit took the audio back before or during the conversation.
    var onPlacedCallAudioDeactivated: (@MainActor () -> Void)? { get set }
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
    /// The phone's voice conversation is running: not a sheet that is open
    /// with no conversation behind it, and not one that failed to start.
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
    /// A call isn't placed from here: CarPlay, or a call the Watch runs,
    /// has the conversation's own call screen.
    var runsElsewhere: @MainActor () -> Bool
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
            setCallActive: { AppStateRuntimeRegistry.shared.existing?.setPlacedPhoneCallActive($0) },
            runsElsewhere: { AppStateRuntimeRegistry.shared.existing?.voiceCallRunsElsewhere ?? true }
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

    enum StartResult: Equatable {
        case call(UUID, UUID)
        case withoutCall
        case cancelled
    }

    /// How often a running call re-reads the conversation: a mute made in
    /// the app reaches the system's screen, and a conversation that ended
    /// without the views seeing it still hangs the call up.
    static let followInterval: Duration = .milliseconds(500)
    /// If activation never arrives, end the call rather than start audio
    /// while CallKit still owns (or is about to own) the session.
    static let callAudioTimeout: Duration = .seconds(2)
    /// How long a placed call waits for the conversation it was placed for.
    /// A refused microphone or an engine that couldn't start ends it sooner
    /// (`voiceStartFailed`); this is the last resort behind that.
    static let voiceStartTimeout: Duration = .seconds(15)
    /// How long a conversation waits for the last call to leave the screen
    /// before abandoning the new open.
    static let previousCallEndWait: Duration = .milliseconds(800)

    private(set) var phase: Phase = .idle
    /// The call's mute as CallKit last took it, so only a change is sent.
    /// A mute it refused stays unsent, and the follow loop sends it again.
    private(set) var reportedMuted: Bool?

    private let callKit: VoicePlacedCallKit
    private let audio: VoiceAudioSessionCoordinator
    private let host: VoicePlacedCallHost
    private let callAudioTimeout: Duration
    private let voiceStartTimeout: Duration
    private let followInterval: Duration
    private var followTask: Task<Void, Never>?
    var followTaskForTesting: Task<Void, Never>? { followTask }
    /// The conversation was seen running since the call was placed. An end
    /// before that is a conversation that never started, not one that ended.
    private var sawVoice = false
    /// When a call was placed ahead of its conversation, the last moment to
    /// wait for it.
    private var voiceStartDeadline: ContinuousClock.Instant?
    /// CallKit activated the current call's audio. Kept, because it can
    /// arrive before the conversation's open asks for it.
    private var isCallAudioActive = false
    /// Each didActivate owns a different start; deactivation revokes it.
    private var audioGeneration: UUID?
    private var callWasShown = false
    private var callGeneration: UUID?
    private var pendingMuteReport: UUID?
    /// Whoever waits for the call's audio: the conversation's open.
    private var callAudioWaiters: [CheckedContinuation<StartResult, Never>] = []
    private(set) var isWaitingForCallAudio = false

    /// `callKit` and `audio` default inside the body: `.shared` of a
    /// MainActor type can't be read from a default argument.
    init(
        callKit: VoicePlacedCallKit? = nil,
        audio: VoiceAudioSessionCoordinator? = nil,
        host: VoicePlacedCallHost? = nil,
        callAudioTimeout: Duration = VoicePlacedCalls.callAudioTimeout,
        voiceStartTimeout: Duration = VoicePlacedCalls.voiceStartTimeout,
        followInterval: Duration = VoicePlacedCalls.followInterval
    ) {
        let callKit = callKit ?? HermesNativeCalls.shared
        self.callKit = callKit
        self.audio = audio ?? .shared
        self.host = host ?? .appState
        self.callAudioTimeout = callAudioTimeout
        self.voiceStartTimeout = voiceStartTimeout
        self.followInterval = followInterval
        callKit.onPlacedCallStarted = { [weak self] in self?.started() }
        callKit.onPlacedCallAudioActivated = { [weak self] in self?.audioActivated() }
        callKit.onPlacedCallAudioDeactivated = { [weak self] in self?.audioDeactivated() }
        callKit.onPlacedCallEnded = { [weak self] bySystem in self?.ended(bySystem: bySystem) }
        callKit.onPlacedCallMuteChanged = { [weak self] muted in self?.muteChanged(muted) }
    }

    deinit { followTask?.cancel() }

    // MARK: Starting

    /// Places the call before the conversation opens, and waits for CallKit
    /// to activate its audio, so the engine starts on the session CallKit
    /// took rather than one it is about to. A refused placement may use the
    /// app's own controls; a hangup or activation timeout cancels the open.
    @discardableResult
    func prepareForVoiceStart() async -> StartResult {
        // A conversation that ended as this one opens leaves its call on the
        // screen for a moment: the new call waits for it rather than being
        // dropped. If it does not leave in time, the new open is cancelled.
        let deadline = ContinuousClock.now + Self.previousCallEndWait
        while phase == .ending, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return .cancelled }
        }
        guard !Task.isCancelled, phase != .ending else { return .cancelled }
        guard placeIfWanted(sawVoice: false) else { return .withoutCall }
        return await waitForCallAudio()
    }

    /// Recheck after the await: the call may have ended or been replaced
    /// before the caller got back onto the main actor.
    func canStartVoice(_ result: StartResult) -> Bool {
        guard !Task.isCancelled else { return false }
        switch result {
        case .call(let generation, let activation):
            return callGeneration == generation && audioGeneration == activation && phase == .running && isCallAudioActive
        case .withoutCall:
            return phase == .idle
        case .cancelled:
            return false
        }
    }

    func cancelVoiceStart(_ result: StartResult) {
        guard case .call(let generation, _) = result, callGeneration == generation else { return }
        endFromApp()
    }

    /// Snapshot at the scheduling boundary; another activation cannot reuse it.
    var currentVoiceStart: StartResult {
        if phase == .idle { return .withoutCall }
        guard phase == .running, isCallAudioActive, let callGeneration, let audioGeneration else { return .cancelled }
        return .call(callGeneration, audioGeneration)
    }

    func captureAuthorization(
        _ widget: WidgetInitialCaptureAuthorization?,
        for start: StartResult,
        onInvalid: @escaping @MainActor () -> Void = {}
    ) -> WidgetInitialCaptureAuthorization? {
        guard case .call(let generation, _) = start else { return widget }
        var notified = false
        return WidgetInitialCaptureAuthorization(wrapping: widget) { [weak self] in
            guard let self else { return false }
            let current = self.canStartVoice(start)
            if !current, !notified, self.callGeneration == generation {
                notified = true
                self.cancelVoiceStart(start)
                onInvalid()
            }
            return current
        }
    }

    /// The phone's voice conversation started or ended. The root view calls
    /// this as it changes; a call in progress re-checks on its own too.
    func voiceChanged(running: Bool) {
        if running {
            // A conversation that began while the last call was still
            // ending is placed once that call is gone (`ended`).
            placeIfWanted(sawVoice: true)
        } else {
            endFromApp()
        }
    }

    /// The conversation failed before it ran — a refused microphone, an
    /// engine that couldn't start. Its call ends instead of sitting on the
    /// system's screen alone.
    func voiceStartFailed() {
        guard phase == .placing || phase == .running, !sawVoice else { return }
        endFromApp()
    }

    /// Places the call when the setting asks for it and nothing else has the
    /// system's call screen. Otherwise the conversation carries on as it
    /// played before: on the earpiece, with the app's own controls.
    @discardableResult
    private func placeIfWanted(sawVoice: Bool) -> Bool {
        guard phase == .idle, host.isSettingOn(), callKit.isAvailable, !host.runsElsewhere() else { return false }
        // A call from Hermes already has the system's call screen: one call
        // group, and the conversation that call opened is its own.
        guard !audio.isInNativeCall else { return false }
        // Called as the conversation changes: never place one for a
        // conversation that has already ended. A call placed ahead of its
        // conversation passes sawVoice: false.
        if sawVoice, !host.isVoiceRunning() { return false }
        let name = host.displayName()
        guard callKit.placeCall(named: name) else {
            placedCallsLogger.info("no call placed: CallKit refused the request")
            return false
        }
        phase = .placing
        callGeneration = UUID()
        callWasShown = false
        reportedMuted = nil
        pendingMuteReport = nil
        self.sawVoice = sawVoice
        voiceStartDeadline = sawVoice ? nil : ContinuousClock.now + voiceStartTimeout
        follow()
        return true
    }

    /// CallKit performed the start: the call is on the system's screen. The
    /// coordinator enters the call's session policy here, before CallKit
    /// activates the audio, so a conversation holding the session moves onto
    /// it and the call's own audio is kept.
    private func started() {
        guard phase == .placing else { return }
        phase = .running
        callWasShown = true
        isCallAudioActive = false
        audio.configureForNativeCall(onlyWhenActivated: true)
        host.setCallActive(true)
        // CallKit's screen starts unmuted. A conversation that is already
        // muted (a paused microphone) reaches it on the follow loop's next
        // tick: a mute sent before CallKit had the call would be refused.
        if reportedMuted == nil { reportedMuted = false }
    }

    /// CallKit activated the call's audio: the conversation may start or
    /// resume on it.
    private func audioActivated() {
        guard phase == .running, let generation = callGeneration else { return }
        if !isCallAudioActive { audioGeneration = UUID() }
        isCallAudioActive = true
        audio.nativeCallAudioActivated()
        guard let audioGeneration else { return }
        resumeCallAudioWaiters(.call(generation, audioGeneration))
    }

    private func audioDeactivated() {
        isCallAudioActive = false
        audioGeneration = nil
        audio.nativeCallAudioDeactivated()
    }

    private func waitForCallAudio() async -> StartResult {
        guard (phase == .placing || phase == .running), let generation = callGeneration else { return .cancelled }
        // CallKit can activate it while the start is being fulfilled.
        if isCallAudioActive, let audioGeneration { return .call(generation, audioGeneration) }
        isWaitingForCallAudio = true
        defer { isWaitingForCallAudio = false }
        let timeout = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.callAudioTimeout) } catch { return }
            guard self.callGeneration == generation else { return }
            self.endFromApp()
        }
        let result: StartResult = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<StartResult, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else {
                    callAudioWaiters.append(continuation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.callGeneration == generation else { return }
                self.endFromApp()
            }
        }
        timeout.cancel()
        return result
    }

    private func resumeCallAudioWaiters(_ result: StartResult) {
        let waiters = callAudioWaiters
        callAudioWaiters = []
        for waiter in waiters { waiter.resume(returning: result) }
    }

    // MARK: Ending

    /// The conversation ended in the app: CallKit hangs its call up.
    private func endFromApp() {
        switch phase {
        case .idle, .ending:
            return
        case .placing, .running:
            phase = .ending
            resumeCallAudioWaiters(.cancelled)
            callKit.requestPlacedCallEnd()
        }
    }

    /// CallKit's call is gone: its screen's End, a reset, an end asked for
    /// here, or a request CallKit refused. The conversation it carried ends
    /// only when the user ended the call, never when Conduit was the one
    /// hanging up (or the call never was on screen).
    private func ended(bySystem: Bool) {
        guard phase != .idle else { return }
        // A refused placement can fall back; an end cancels its pending open.
        let wasOnScreen = callWasShown
        let hadEarlyMute = !wasOnScreen && reportedMuted != nil
        let startResult: StartResult = phase == .placing && !bySystem ? .withoutCall : .cancelled
        phase = .idle
        stopFollowing()
        reportedMuted = nil
        pendingMuteReport = nil
        callGeneration = nil
        callWasShown = false
        sawVoice = false
        isCallAudioActive = false
        audioGeneration = nil
        voiceStartDeadline = nil
        resumeCallAudioWaiters(startResult)
        // The conversation ends first, as a call from Hermes does: it lets
        // the session go while CallKit still owns it, and only then does the
        // coordinator leave the call's policy.
        if bySystem, wasOnScreen { host.endVoice() }
        audio.nativeCallEnded()
        if wasOnScreen || hadEarlyMute { host.setCallActive(false) }
        // A conversation that began while this call was still ending gets
        // its own call now. Only after a call that really was on screen: a
        // placement CallKit refused must not be tried again and again.
        if wasOnScreen, !bySystem, host.isVoiceRunning() { placeIfWanted(sawVoice: true) }
    }

    // MARK: Mute

    /// The system's call screen muted or unmuted the call.
    private func muteChanged(_ muted: Bool) {
        guard phase == .running || phase == .placing else { return }
        reportedMuted = muted
        pendingMuteReport = nil
        host.setVoiceMuted(muted)
    }

    /// Tells CallKit this phone's mute. Taken only when CallKit says so, so
    /// a refused mute is sent again by the follow loop.
    private func reportMuted(_ muted: Bool) {
        guard pendingMuteReport == nil, let generation = callGeneration else { return }
        let request = UUID()
        pendingMuteReport = request
        callKit.reportPlacedCallMuted(muted) { [weak self] taken in
            guard let self, self.callGeneration == generation, self.pendingMuteReport == request else { return }
            self.pendingMuteReport = nil
            if taken { self.reportedMuted = muted }
        }
    }

    // MARK: Following the conversation

    /// Re-reads the conversation while the call is up. Called by the loop
    /// below every `followInterval`, and directly by the tests.
    func followOnce() {
        guard phase == .running || phase == .placing else { return }
        let voiceIsRunning = host.isVoiceRunning()
        // Only once CallKit shows the call: a mute for a call it doesn't
        // have yet is refused. A prepared classic session is not running
        // yet and must not overwrite a mute made while activation waits.
        if phase == .running, voiceIsRunning, let muted = host.voiceMuted(), muted != reportedMuted {
            reportMuted(muted)
        }
        if voiceIsRunning {
            sawVoice = true
            voiceStartDeadline = nil
            return
        }
        if sawVoice {
            // The conversation is over (an End, a failed engine, a
            // sign-out): so is the call.
            endFromApp()
        } else if let deadline = voiceStartDeadline, ContinuousClock.now >= deadline {
            // It never started: a refused microphone, an engine that
            // couldn't, a sheet closed before it did.
            endFromApp()
        }
    }

    private func follow() {
        stopFollowing()
        let interval = followInterval
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, self != nil else { return }
                self?.followOnce()
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
