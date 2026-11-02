#if LAA_BUILD && targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Window geometry is independent of text and control styling tokens.
///
/// Catalyst keeps the "Scale Interface to Match iPad" idiom, so one UIKit
/// point is drawn at about 0.77 Mac points. The numbers below are the Mac
/// sizes the desktop layout is designed for, divided by that scale: a
/// 1280×820 Mac window is 1662×1065 UIKit points. The window resizes freely
/// above the minimum (full screen and Split View included), so a wide
/// MacBook or Mac mini display gets a wide layout instead of a stretched
/// phone.
enum LAAMacWindow {
    /// UIKit points per Mac point under "Scale Interface to Match iPad".
    static let scale: CGFloat = 0.77

    /// 1280×820 Mac points: the default desktop window.
    static let initialWidth: CGFloat = 1662
    static let initialHeight: CGFloat = 1065
    /// 900×600 Mac points: narrow enough for Split View, wide enough for a
    /// list beside its detail.
    static let minimumWidth: CGFloat = 1169
    static let minimumHeight: CGFloat = 779
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
