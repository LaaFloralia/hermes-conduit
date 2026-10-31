#if LAA_BUILD && targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Window geometry is independent of text and control styling tokens.
enum LAAMacWindow {
    // Scale Interface to Match iPad maps UIKit points to about 77% of Mac
    // points. These produce roughly 460×860 and 400×640 native windows,
    // including the title bar, while retaining the iPhone's control style.
    static let initialWidth: CGFloat = 598
    static let initialHeight: CGFloat = 1075
    static let minimumWidth: CGFloat = 520
    static let minimumHeight: CGFloat = 790
    static let contentWidth: CGFloat = 623
}

struct LAAMacWindowConstraints: UIViewRepresentable {
    func makeUIView(context: Context) -> ConstraintView { ConstraintView() }
    func updateUIView(_ view: ConstraintView, context: Context) { view.apply() }

    final class ConstraintView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }
        func apply() {
            window?.windowScene?.sizeRestrictions?.minimumSize = CGSize(
                width: LAAMacWindow.minimumWidth, height: LAAMacWindow.minimumHeight
            )
        }
    }
}
#endif
