#if LAA_BUILD && !targetEnvironment(macCatalyst)
import LAATokens
import SwiftUI
import UIKit

/// Template artwork goes into SwiftUI's native tab labels. The system owns
/// the accessible tab name, selection, badge and Liquid Glass presentation.
@MainActor
enum LAANativeTabIcons {
    static func image(_ tab: LAATab, selected: Bool) -> UIImage {
        guard let pair = artwork[tab] else { return glyph(tab.icon, selected: selected) }
        return selected ? pair.selected : pair.regular
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
#endif
