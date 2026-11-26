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

        func applyIcons() {
            guard let bar = tabBarController?.tabBar, let items = bar.items,
                  items.count == LAATab.destinations.count else { return }
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
