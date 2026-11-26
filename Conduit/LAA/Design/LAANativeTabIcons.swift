#if LAA_BUILD && !targetEnvironment(macCatalyst)
import LAATokens
import SwiftUI
import UIKit

/// Configure the existing tab items rather than building another navigation bar.
/// This retains the system's Liquid Glass, badge and per-screen visibility behaviour.
struct LAANativeTabIcons: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ controller: Probe, context: Context) { controller.applyIcons() }

    final class Probe: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyIcons()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyIcons()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyIcons()
        }

        func applyIcons() {
            // SwiftUI's hosted background controller is not necessarily parented under
            // the tab controller. Fall back to the native bar in this window only.
            guard let items = Self.items(in: tabBarController?.tabBar)
                    ?? viewIfLoaded?.window.flatMap(Self.findItems(in:)) else { return }
            for (tab, item) in zip(LAATab.destinations, items) {
                let artwork = Self.artwork[tab]
                let identifier = "laa.tab.\(tab.rawValue)"
                item.accessibilityIdentifier = identifier
                item.accessibilityLabel = tab.title
                if item.title != nil { item.title = nil }
                if item.image !== artwork?.regular { item.image = artwork?.regular }
                if item.selectedImage !== artwork?.selected { item.selectedImage = artwork?.selected }
            }
        }

        private static func items(in bar: UITabBar?) -> [UITabBarItem]? {
            guard let items = bar?.items, items.count == LAATab.destinations.count else { return nil }
            return items
        }

        private static func findItems(in view: UIView) -> [UITabBarItem]? {
            if let bar = view as? UITabBar, let items = items(in: bar) { return items }
            for subview in view.subviews.reversed() {
                if let items = findItems(in: subview) { return items }
            }
            return nil
        }

        private static let artwork: [LAATab: (regular: UIImage, selected: UIImage)] = Dictionary(
            uniqueKeysWithValues: LAATab.destinations.map { ($0, (glyph($0.icon, selected: false), glyph($0.icon, selected: true))) }
        )

        private static func glyph(_ icon: LAAIcon, selected: Bool) -> UIImage {
            let size = CGSize(width: LAAIconSize.tab, height: LAAIconSize.tab)
            return UIGraphicsImageRenderer(size: size).image { render in
                let path = LAAGlyph(selected ? icon.fillPath : icon.regularPath).path(in: CGRect(origin: .zero, size: size))
                render.cgContext.setFillColor(UIColor(Color(laa: LAAThemeSets.laa.light.text)).cgColor)
                render.cgContext.addPath(path.cgPath)
                render.cgContext.fillPath()
            }.withRenderingMode(.alwaysTemplate)
        }
    }
}
#endif
