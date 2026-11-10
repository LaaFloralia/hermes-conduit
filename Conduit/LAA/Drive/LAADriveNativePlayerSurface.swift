#if LAA_BUILD
import AVKit
import SwiftUI

/// The owner supplies the AVPlayer and retains the delegate for the full PiP
/// lifecycle. Replacing or dismantling this view must not close that player.
struct LAADriveNativePlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    let delegate: (any AVPlayerViewControllerDelegate)?
    var onReadyForDisplay: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReadyForDisplay) }

    final class Coordinator {
        var onReady: () -> Void
        private var observation: NSKeyValueObservation?
        init(onReady: @escaping () -> Void) { self.onReady = onReady }
        func observe(_ controller: AVPlayerViewController) {
            observation = controller.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] controller, _ in
                guard controller.isReadyForDisplay else { return }
                Task { @MainActor in self?.onReady() }
            }
        }
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = delegate
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        context.coordinator.observe(controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.delegate = delegate
        context.coordinator.onReady = onReadyForDisplay
    }
}
#endif
