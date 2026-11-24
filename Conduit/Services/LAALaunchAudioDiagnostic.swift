#if LAA_BUILD && DEBUG && !targetEnvironment(macCatalyst)
import AVFAudio
import Foundation
import OSLog

@MainActor enum LAALaunchAudioDiagnostic {
    private static let launchArgument = "-LAA_DEBUG_LAUNCH_AUDIO_REPORT"
    private static var didCapture = false
    private static let logger = Logger(subsystem: "com.laa.conduit", category: "LaunchAudio")

    static func begin() {
        guard !didCapture, ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        didCapture = true
        // Reading this property does not activate or set a category.
        let begin = Date.now
        let before = AVAudioSession.sharedInstance().isOtherAudioPlaying
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let after = AVAudioSession.sharedInstance().isOtherAudioPlaying
            logger.notice("other audio before=\(before, privacy: .public) after=\(after, privacy: .public)")
            MetricKitReports.shared.recordLaunchAudio(before: before, after: after, begin: begin, end: .now)
        }
    }
}
#endif
