#if LAA_BUILD
import SwiftUI
import UIKit

/// Callers pass only an authorized temporary file or a validated Drive link.
/// The completion callback releases the temporary file lease; the sheet's
/// dismissal handler should also release it, which is safe to do twice.
struct LAADriveShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in onComplete() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
#endif
