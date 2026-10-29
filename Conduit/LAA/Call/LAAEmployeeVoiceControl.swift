#if LAA_BUILD
import Combine
import Foundation

/// Reads the existing voice engines; it does not place calls or own audio.
struct LAAEmployeeVoiceStatus: Equatable {
    var phase: LAAEmployeeCallPhase
    var muted = false
    var speaker = false
    var nativeRoute = false
    var level: Float?
    var voiceNote: String? = nil
}

enum LAAEmployeeVoiceOpenResult {
    case opened(LAAEmployeeCallContext)
    case ended
    case failed
}

/// A narrow seam around AppState makes start/end races testable without CallKit.
@MainActor
struct LAAEmployeeVoiceHost {
    var unavailable: () -> String?
    var consent: (LAAEmployeeCallContext) -> LiveVoiceModeName?
    var grant: (LiveVoiceModeName) -> Void
    var open: (LAAEmployeeCallContext) async -> LAAEmployeeVoiceOpenResult
    var status: () -> LAAEmployeeVoiceStatus
    var observe: (@escaping () -> Void) -> [AnyCancellable]
    var beginClassicListening: () -> Void
    var mute: (Bool) -> Void
    var speaker: (Bool) -> Void
    var end: () -> Void
}

@MainActor
final class LAAEmployeeVoiceControl: LAAEmployeeCallControlling {
    var onUpdate: ((LAAEmployeeCallSnapshot) -> Void)?
    private var host: LAAEmployeeVoiceHost?
    private var context: LAAEmployeeCallContext?
    private var startTask: Task<Void, Never>?
    private var observations: [AnyCancellable] = []
    private var connectedAt: Date?
    private var lastSnapshot: LAAEmployeeCallSnapshot?

    init(host: LAAEmployeeVoiceHost? = nil) { self.host = host }

    func bind(_ appState: AppState) {
        guard context == nil else { return }
        host = .appState(appState)
    }

    var unavailableReason: String? { host?.unavailable() ?? (host == nil ? "通話を準備中です" : nil) }

    func requiredConsent(for context: LAAEmployeeCallContext) -> LiveVoiceModeName? {
        host?.consent(context)
    }

    func grantConsent(_ mode: LiveVoiceModeName) { host?.grant(mode) }

    func start(_ context: LAAEmployeeCallContext) {
        guard let host, self.context == nil else { return }
        self.context = context
        connectedAt = nil
        lastSnapshot = nil
        startTask = Task { [weak self] in
            let opened = await host.open(context)
            guard let self, !Task.isCancelled, self.context?.id == context.id else { return }
            self.startTask = nil
            switch opened {
            case .ended:
                self.finish()
                return
            case .failed:
                self.publish(phase: .failed("通話を開始できませんでした"), status: host.status())
                return
            case .opened(let opened):
                self.context = opened
            }
            self.observations = host.observe { [weak self] in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            // Classic normally starts from VoiceConversationSheet's task.
            // That sheet is hidden while the LAA call screen owns it.
            host.beginClassicListening()
            self.refresh()
        }
    }

    func setMuted(_ muted: Bool) { host?.mute(muted) }
    func setSpeaker(_ speaker: Bool) { host?.speaker(speaker) }

    func end() {
        guard let context else { return }
        startTask?.cancel()
        startTask = nil
        // This is the same close path CallKit uses, including an open still
        // waiting for its audio. It never changes the audio session itself.
        host?.end()
        observations.removeAll()
        self.context = nil
        lastSnapshot = nil
        onUpdate?(LAAEmployeeCallSnapshot(context: context, phase: .ended))
    }

    private func refresh() {
        guard context != nil, let host else { return }
        let status = host.status()
        if case .ended = status.phase {
            finish()
            return
        }
        publish(phase: status.phase, status: status)
    }

    private func finish() {
        guard let context else { return }
        observations.removeAll()
        self.context = nil
        lastSnapshot = nil
        onUpdate?(LAAEmployeeCallSnapshot(context: context, phase: .ended))
    }

    private func publish(phase: LAAEmployeeCallPhase, status: LAAEmployeeVoiceStatus) {
        guard let context else { return }
        if case .connected = phase, connectedAt == nil { connectedAt = Date() }
        let next = LAAEmployeeCallSnapshot(context: context, phase: phase, connectedAt: connectedAt,
                                           muted: status.muted, speaker: status.speaker,
                                           usesSystemRoutePicker: status.nativeRoute, audioLevel: status.level,
                                           voiceNote: status.voiceNote)
        guard next != lastSnapshot else { return }
        lastSnapshot = next
        onUpdate?(next)
    }
}

private extension LAAEmployeeVoiceHost {
    static func appState(_ app: AppState) -> LAAEmployeeVoiceHost {
        let audio = VoiceAudioSessionCoordinator.shared
        return LAAEmployeeVoiceHost(
            unavailable: { [weak app] in
                guard let app else { return "通話を準備中です" }
                return app.isVoiceCallInProgress ? "別の通話を終了してください" : nil
            },
            consent: { [weak app] context in
                if LAAStaff(profile: context.profile) != nil { return LiveVoiceProviderConsent.missing(.gptLive) }
                guard let app, let engine = app.configuredLiveVoiceEngine(profile: app.activeProfile),
                      let mode = mode(for: engine) else { return nil }
                return LiveVoiceProviderConsent.missing(mode)
            },
            grant: { [weak app] in app?.setLiveVoiceConsent(true, for: $0) },
            open: { [weak app] context in
                guard let app, app.isConnected, !app.isVoiceCallInProgress,
                      app.conversationIdentityProfile == context.profile,
                      app.activeSessionId == context.conversationID else { return .failed }
                var nativeCallWasActive = false
                let nativeCallObservation = app.$isPlacedPhoneCallActive.sink { active in
                    if active { nativeCallWasActive = true }
                }
                defer { nativeCallObservation.cancel() }
                let employeePlan = app.laaEmployeeCallPlan(profile: context.profile)
                app.laaEmployeeGPTLivePlan = employeePlan
                let started = await app.openVoiceConversation(PendingVoiceIntent(
                    profile: app.activeProfile, startsFreshConversation: false, source: .composer))
                if !started, app.laaEmployeeGPTLivePlan == employeePlan { app.laaEmployeeGPTLivePlan = nil }
                guard !Task.isCancelled else {
                    if app.laaEmployeeGPTLivePlan == employeePlan { app.laaEmployeeGPTLivePlan = nil }
                    return .ended
                }
                if !started, nativeCallWasActive, !app.isPlacedPhoneCallActive { return .ended }
                guard started, app.isVoiceCallScreenPresented,
                      app.conversationIdentityProfile == context.profile,
                      context.conversationID == nil || app.activeSessionId == context.conversationID else {
                    if started, app.isVoiceCallScreenPresented {
                        app.endVoiceForPlacedCall()
                        app.voicePlacedCalls.voiceChanged(running: false)
                    }
                    if app.laaEmployeeGPTLivePlan == employeePlan { app.laaEmployeeGPTLivePlan = nil }
                    return .failed
                }
                return .opened(LAAEmployeeCallContext(id: context.id, profile: context.profile, name: context.name,
                                                       conversationID: app.activeSessionId ?? context.conversationID))
            },
            status: { [weak app] in
                guard let app else { return LAAEmployeeVoiceStatus(phase: .ended) }
                return status(app, audio: audio)
            },
            observe: { [weak app] changed in
                guard let app else { return [] }
                var result = [app.objectWillChange.sink { _ in changed() },
                              app.voiceConversationController.objectWillChange.sink { _ in changed() },
                              audio.objectWillChange.sink { _ in changed() }]
                if app.showGeminiLiveSheet { result.append(app.geminiLiveController.objectWillChange.sink { _ in changed() }) }
                if app.showQwenLiveSheet { result.append(app.qwenLiveController.objectWillChange.sink { _ in changed() }) }
                if app.showGrokLiveSheet { result.append(app.grokLiveController.objectWillChange.sink { _ in changed() }) }
                if app.showLocalLiveSheet { result.append(app.localLiveController.objectWillChange.sink { _ in changed() }) }
                if app.showGPTLiveSheet { result.append(app.gptLiveController.objectWillChange.sink { _ in changed() }) }
                return result
            },
            beginClassicListening: { [weak app] in app?.startDeferredVoiceSheetAutoListen() },
            mute: { [weak app] in app?.setVoiceMutedForNativeCall($0) },
            speaker: { audio.setConversationSpeaker($0) },
            end: { [weak app] in
                guard let app else { return }
                app.endVoiceForPlacedCall()
                app.voicePlacedCalls.voiceChanged(running: false)
                app.laaEmployeeGPTLivePlan = nil
            }
        )
    }

    static func mode(for engine: VoiceCallEngine) -> LiveVoiceModeName? {
        switch engine {
        case .geminiLive: return .geminiLive
        case .qwenLive: return .qwenLive
        case .gptLive: return .gptLive
        case .grokLive: return .grokLive
        case .localLive: return .localLive
        }
    }

    static func status(_ app: AppState, audio: VoiceAudioSessionCoordinator) -> LAAEmployeeVoiceStatus {
        let phase: LAAEmployeeCallPhase
        var level: Float?
        if app.showVoiceSheet {
            if case .failed = app.voiceConversationController.state,
               !app.voiceConversationController.failedForAudioInterruption {
                phase = .failed("音声に接続できませんでした")
            } else {
                phase = .connected
                level = Float(VoiceLevelMeterMath.displayFraction(forLevel: app.voiceConversationController.microphoneLevel))
            }
        } else if app.showGeminiLiveSheet {
            phase = livePhase(app.geminiLiveController.phase, scheduled: app.hasScheduledLiveVoiceStart)
        } else if app.showQwenLiveSheet {
            phase = livePhase(app.qwenLiveController.phase, scheduled: app.hasScheduledLiveVoiceStart)
        } else if app.showGrokLiveSheet {
            phase = livePhase(app.grokLiveController.phase, scheduled: app.hasScheduledLiveVoiceStart)
        } else if app.showLocalLiveSheet {
            phase = livePhase(app.localLiveController.phase, scheduled: app.hasScheduledLiveVoiceStart)
        } else if app.showGPTLiveSheet {
            phase = gptPhase(app.gptLiveController.phase, scheduled: app.hasScheduledLiveVoiceStart)
        } else {
            phase = .ended
        }
        return LAAEmployeeVoiceStatus(phase: phase, muted: app.nativeCallVoiceMuted ?? false,
                                      speaker: audio.conversationSpeakerChosen,
                                      nativeRoute: audio.isInNativeCall, level: level,
                                      voiceNote: app.showGPTLiveSheet ? app.gptLiveController.voiceNote : nil)
    }

    static func livePhase(_ phase: GeminiLiveConversationController.Phase, scheduled: Bool) -> LAAEmployeeCallPhase {
        switch phase {
        case .idle: return scheduled ? .connecting : .ended
        case .connecting, .reconnecting: return .connecting
        case .listening, .speaking, .paused: return .connected
        case .ending: return .ending
        case .failed: return .failed("音声に接続できませんでした")
        }
    }

    static func gptPhase(_ phase: GPTLiveConversationController.Phase, scheduled: Bool) -> LAAEmployeeCallPhase {
        switch phase {
        case .idle: return scheduled ? .connecting : .ended
        case .connecting: return .connecting
        case .listening, .speaking, .paused: return .connected
        case .ending: return .ending
        case .failed(let reason): return .failed(reason)
        }
    }
}
#endif
