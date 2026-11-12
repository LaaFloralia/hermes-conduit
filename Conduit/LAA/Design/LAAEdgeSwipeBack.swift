#if LAA_BUILD
import SwiftUI
import UIKit

extension View {
    /// Keeps the system's left-edge swipe back on a pushed screen that hides
    /// the standard Back button for its own (LAABackToolbar). Hiding it also
    /// turns the swipe off; this hands the swipe a delegate that allows it
    /// whenever there is a screen to go back to, and gives the navigation
    /// controller its own delegate back when the screen leaves.
    func laaEdgeSwipeBack(_ enabled: Bool = true) -> some View {
        background {
            if enabled {
                LAAEdgeSwipeBackInstaller()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct LAAEdgeSwipeBackInstaller: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> LAAEdgeSwipeBackController { LAAEdgeSwipeBackController() }
    func updateUIViewController(_ controller: LAAEdgeSwipeBackController, context: Context) {}
    static func dismantleUIViewController(_ controller: LAAEdgeSwipeBackController, coordinator: ()) {
        controller.restore()
    }
}

final class LAAEdgeSwipeBackController: UIViewController, UIGestureRecognizerDelegate {
    private weak var navigation: UINavigationController?
    private weak var previousDelegate: UIGestureRecognizerDelegate?
    private var previouslyEnabled = true
    private var installed = false

    override func loadView() {
        view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        install()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        install()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        restore()
    }

    private func install() {
        guard !installed, let navigation = navigationController,
              let recognizer = navigation.interactivePopGestureRecognizer else { return }
        self.navigation = navigation
        previousDelegate = recognizer.delegate
        previouslyEnabled = recognizer.isEnabled
        recognizer.delegate = self
        recognizer.isEnabled = true
        installed = true
    }

    func restore() {
        guard installed else { return }
        installed = false
        if let recognizer = navigation?.interactivePopGestureRecognizer, recognizer.delegate === self {
            recognizer.delegate = previousDelegate
            recognizer.isEnabled = previouslyEnabled
        }
        navigation = nil
        previousDelegate = nil
    }

    /// Only with a screen beneath and no transition already running, so the
    /// list itself never swipes and a second swipe can't start mid-pop.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigation, navigation.viewControllers.count > 1 else { return false }
        return navigation.transitionCoordinator == nil
    }

    /// A drag that starts at the very edge goes back, as on any iOS screen;
    /// the transcript's and the field's scrolling wait only for that edge.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
    }
}
#endif
