import SwiftUI
#if os(iOS)
import Combine
import UIKit
#endif

/// Whether the software keyboard is on screen, for the glass tab bar: the bar and its content reserve go away
/// while it is shown (tokens `tabBar.iphone.hidden`). One observer for the whole process; hosts do not need
/// their own. Always false where there is no software keyboard (macOS, watchOS).
@MainActor
@Observable
final class LAAKeyboardState {
    static let shared = LAAKeyboardState()

    private(set) var isVisible = false

    /// Less of the keyboard than this on screen is not "shown": with a hardware keyboard only its assistant
    /// bar (55–69 pt) remains.
    nonisolated static let minimumHeight: Double = 120

    /// The rule, as a pure function: the keyboard's end frame covers more than `minimumHeight` of the screen.
    nonisolated static func covers(endFrame: CGRect, screen: CGRect) -> Bool {
        let shown = endFrame.intersection(screen)
        return !shown.isNull && shown.height > minimumHeight
    }

    #if os(iOS)
    @ObservationIgnored private var observers: [AnyCancellable] = []

    private init() {
        let center = NotificationCenter.default
        let frameChanges = [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillChangeFrameNotification]
        observers = frameChanges.map { name in
            center.publisher(for: name).sink { [weak self] note in
                guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                else { return }
                let screen = (note.object as? UIScreen)?.bounds ?? UIScreen.main.bounds
                self?.set(Self.covers(endFrame: end, screen: screen))
            }
        }
        observers.append(center.publisher(for: UIResponder.keyboardWillHideNotification).sink { [weak self] _ in
            self?.set(false)
        })
    }
    #else
    private init() {}
    #endif

    private func set(_ visible: Bool) {
        if isVisible != visible { isVisible = visible }
    }
}
