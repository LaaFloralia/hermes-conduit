#if LAA_BUILD
import AVKit
import SwiftUI

/// The owner supplies the AVPlayer and retains the delegate for the full PiP
/// lifecycle. Replacing or dismantling this view must not close that player.
struct LAADriveNativePlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    let delegate: (any AVPlayerViewControllerDelegate)?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = delegate
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.delegate = delegate
    }
}
#endif
