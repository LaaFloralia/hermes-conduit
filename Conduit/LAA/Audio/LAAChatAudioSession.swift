#if LAA_BUILD
import AVFAudio
import OSLog

private let laaChatAudioLogger = Logger(subsystem: "com.milim.relay", category: "LAAChatAudio")

/// The session seam the LAA idle policy writes through. A test substitutes a
/// fake, so the policy's decisions are checked without touching the
/// process-global audio session.
@MainActor
protocol LAAChatAudioSessionControlling: AnyObject {
    var category: AVAudioSession.Category { get }
    var categoryOptions: AVAudioSession.CategoryOptions { get }
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

/// Who holds the audio session right now, as the idle policy sees it. The
/// voice side is the existing `VoiceAudioSessionCoordinator` (a conversation,
/// read aloud or dictation); CallKit owns a native call's session itself.
struct LAAChatAudioVoiceState: Equatable {
    /// The voice coordinator holds the session.
    var holdsSession = false
    /// A CallKit call is up: only CallKit may reconfigure or deactivate it.
    var nativeCall = false

    static let idle = Self()
    static let conversation = Self(holdsSession: true)

    /// Nothing on the voice side can be disturbed by the idle policy.
    var leavesIdleAlone: Bool { holdsSession || nativeCall }
}

/// What the idle policy asks of the session, as data.
enum LAAChatAudioStep: Equatable {
    /// Play alongside whatever the user is listening to, and never activate.
    case mixWithOtherAudio
    /// Hand the audio back so the paused music resumes.
    case releaseToOtherAudio
}

/// BUS-332: opening a conversation must not stop the music playing in another
/// app. The chat and its muted idle video only ever ask for `.ambient` with
/// `.mixWithOthers`, and never activate the session, so a display-only video
/// cannot take the audio away. A call or voice input is not this policy's:
/// `VoiceAudioSessionCoordinator` switches to `.playAndRecord`/`.voiceChat`
/// when it takes the session and deactivates with
/// `.notifyOthersOnDeactivation` when its last owner releases. While that
/// holds, the idle policy writes nothing, so the call's category, its
/// `defaultToSpeaker` and CallKit's own session stay exactly as they are.
struct LAAChatAudioPolicy: Equatable {
    /// Never `.playback` or `.playAndRecord`: both are non-mixable, and any
    /// media the app plays would silence the other app the moment it
    /// activates the session. `.ambient` is also silenced by the ring switch,
    /// which is what an idle video wants.
    static let category: AVAudioSession.Category = .ambient
    static let mode: AVAudioSession.Mode = .default
    static let options: AVAudioSession.CategoryOptions = [.mixWithOthers]

    /// A chat screen (or the muted idle video it shows) is about to appear.
    func chatShown(voice: LAAChatAudioVoiceState) -> [LAAChatAudioStep] {
        guard !voice.leavesIdleAlone else { return [] }
        return [.mixWithOtherAudio]
    }

    /// The call or voice input ended: mix again, and release the session first
    /// so the other app's playback resumes. A call that is still winding down
    /// (the coordinator has not released yet) only gets the category back;
    /// that release is the coordinator's, with `.notifyOthersOnDeactivation`.
    func voiceEnded(voice: LAAChatAudioVoiceState) -> [LAAChatAudioStep] {
        guard !voice.nativeCall else { return [] }
        return voice.holdsSession ? [.mixWithOtherAudio] : [.mixWithOtherAudio, .releaseToOtherAudio]
    }
}

/// Applies the idle policy through the seam. The category is only written when
/// the session is not already mixing, and the session is never activated here:
/// the idle chat holds no audio of its own.
@MainActor
final class LAAChatAudioSession {
    static let shared = LAAChatAudioSession()

    private let session: LAAChatAudioSessionControlling
    private let voiceState: @MainActor () -> LAAChatAudioVoiceState
    private let policy = LAAChatAudioPolicy()

    init(
        session: LAAChatAudioSessionControlling? = nil,
        voiceState: (@MainActor () -> LAAChatAudioVoiceState)? = nil
    ) {
        self.session = session ?? LAASystemChatAudioSession()
        self.voiceState = voiceState ?? {
            let coordinator = VoiceAudioSessionCoordinator.shared
            return LAAChatAudioVoiceState(
                holdsSession: coordinator.appliedPolicy != nil,
                nativeCall: coordinator.isInNativeCall
            )
        }
    }

    /// The conversation screen, its header avatar and its muted idle video.
    func chatShown() {
        apply(policy.chatShown(voice: voiceState()))
    }

    /// The conversation's call, or any voice input, has ended.
    func voiceEnded() {
        apply(policy.voiceEnded(voice: voiceState()))
    }

    private func apply(_ steps: [LAAChatAudioStep]) {
        for step in steps {
            switch step {
            case .mixWithOtherAudio:
                guard !isMixing else { continue }
                do {
                    try session.setCategory(LAAChatAudioPolicy.category,
                                            mode: LAAChatAudioPolicy.mode,
                                            options: LAAChatAudioPolicy.options)
                } catch {
                    laaChatAudioLogger.error(
                        "idle audio category failed: \(LogRedaction.describing(error), privacy: .public)"
                    )
                }
            case .releaseToOtherAudio:
                // Idempotent: the coordinator's own release may have run
                // already, and deactivating an inactive session is a no-op.
                do {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                } catch {
                    laaChatAudioLogger.error(
                        "idle audio release failed: \(LogRedaction.describing(error), privacy: .public)"
                    )
                }
            }
        }
    }

    private var isMixing: Bool {
        session.category == LAAChatAudioPolicy.category
            && session.categoryOptions.contains(.mixWithOthers)
    }
}

/// The real session, through the voice coordinator's serial queue: a category
/// change waits (the caller needs the result), a deactivation does not block
/// the main thread.
@MainActor
final class LAASystemChatAudioSession: LAAChatAudioSessionControlling {
    private let session = SystemVoiceAudioSession()

    private var audioSession: AVAudioSession { AVAudioSession.sharedInstance() }

    var category: AVAudioSession.Category { audioSession.category }
    var categoryOptions: AVAudioSession.CategoryOptions { audioSession.categoryOptions }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        try session.setCategory(category, mode: mode, options: options)
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        try session.setActive(active, options: options)
    }
}
#endif
