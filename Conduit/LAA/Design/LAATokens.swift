#if LAA_BUILD
import LAAKit
import Observation
import SwiftUI
import UIKit

/// The read side of the theme store for legacy SwiftUI/ UIKit callers that still take `Color`.
/// SwiftUI tracks `themeID` when a view resolves a role; UIKit resolves the system traits lazily.
/// Background readers (e.g. attributed text preparation) can safely read the same snapshot.
final class LAASelectedTheme: Observable, @unchecked Sendable {
    static let appGroup: String? = {
        #if DEBUG
        // Keep visual tests entirely outside the real app-group preference.
        if let suite = ProcessInfo.processInfo.environment["LAA_UI_TEST_THEME_SUITE"],
           suite.hasPrefix("laa.appearance-test.") { return suite }
        #endif
        let value = Bundle.main.object(forInfoDictionaryKey: "ConduitLauncherAppGroup") as? String
        return value?.hasPrefix("group.") == true ? value : nil
    }()
    static let shared = LAASelectedTheme()
    private let changes = ObservationRegistrar()
    private let lock = NSLock()
    private var selected = LAAThemeStore.storedThemeID(appGroup: appGroup)

    var themeID: String {
        #if LAA_WIDGET_EXTENSION
        // WidgetKit may reuse the extension process across reload requests.
        return LAAThemeStore.storedThemeID(appGroup: Self.appGroup)
        #else
        changes.access(self, keyPath: \.themeID)
        return lock.withLock { selected }
        #endif
    }

    @MainActor func apply(_ id: String) {
        guard id != themeID else { return }
        changes.withMutation(of: self, keyPath: \.themeID) {
            lock.withLock { selected = id }
        }
    }
}

/// Compatibility spellings for screens adopting the kit incrementally.
/// Store roles as computed values: caching a returned Color freezes the selected theme.
enum LAAColor {
    static var background: Color { themed { $0.raw.bg } }
    static var surface: Color { themed { $0.raw.surface } }
    static var subtleSurface: Color { themed { $0.raw.wash } }
    static var text: Color { themed { $0.raw.text } }
    static var secondaryText: Color { themed { $0.raw.textMuted } }
    static var link: Color { themed { $0.raw.accent } }
    static var separator: Color { themed { $0.increasedContrast ? $0.raw.text : $0.raw.rule } }
    static var selectionFill: Color { themed { $0.raw.selection } }
    static var ownBubble: Color { themed { $0.raw.accentFill } }
    static var ownBubbleText: Color { themed { $0.raw.onAccent } }
    static var second: Color { themed { $0.raw.second } }
    static var filledButton: Color { ownBubble }
    static var filledButtonText: Color { ownBubbleText }
    static var filledControl: Color { filledButton }
    static var filledControlText: Color { filledButtonText }
    static var positive: Color { adaptive { dark, _ in (dark ? LAASemantic.dark : LAASemantic.light).positive } }
    static var caution: Color { adaptive { dark, _ in (dark ? LAASemantic.dark : LAASemantic.light).caution } }
    static var critical: Color { adaptive { dark, _ in (dark ? LAASemantic.dark : LAASemantic.light).critical } }
    static var end: Color { critical }
    static var attention: Color { adaptive { dark, _ in LAAThemeSets.laa.colors(dark: dark).second } }
    // Fixed brand roles, independent of the selected theme. Kit v0.1.0 does not export ruleWarm.
    static let decorativeTan = Color(laa: LAAColorValues.ruleWarm)
    static let ivory = Color(laa: LAAThemeSets.laa.light.bg)
    static var rimLight: Color { adaptive { dark, _ in dark ? LAAThemeSets.laa.light.surface : LAAColorValues.ruleWarm } }

    private static func themed(_ role: @escaping @Sendable (LAAPalette) -> LAARGB) -> Color {
        let theme = LAAThemeSets.set(id: LAASelectedTheme.shared.themeID)
        return adaptive { dark, contrast in role(LAAPalette(theme: theme, dark: dark, increasedContrast: contrast)) }
    }

    private static func adaptive(_ value: @escaping @Sendable (Bool, Bool) -> LAARGB) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = value(traits.userInterfaceStyle == .dark, traits.accessibilityContrast == .high)
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    }
}

/// Points rather than fixed frames: rows and content must grow with Dynamic Type.
extension LAASpacing {
    static let horizontal = LAAType.canvas.marginCompact * LAAType.platformScale
    static let compactHorizontal = horizontal
    static let section = LAASpace.s32
    static let minimumRowHeight = LAAType.canvas.rowMinHeight * LAAType.platformScale
    static let minimumTouchTarget = LAAType.canvas.touchTarget * LAAType.platformScale
}

enum LAARadius {
    static let card = LAAKit.LAARadius.card
    static let bubble = LAAKit.LAARadius.bubble
    static let selectionChip = LAAKit.LAARadius.chip
    static let photo = LAAKit.LAARadius.photo
    static let control = LAAKit.LAARadius.tabBar
}

enum LAAType {
    static let canvas = LAAPlatform.current.canvas
    // Scale Interface to Match iPad; common to the app and its Catalyst targets.
    static let catalystScale: CGFloat = 0.77
    #if targetEnvironment(macCatalyst)
    static let platformScale: CGFloat = 1 / catalystScale
    #else
    static let platformScale: CGFloat = 1
    #endif
    static let iconButton = LAAPlatform.current == .mac ? LAAControl.Mac.iconButton : LAAControl.IPhone.iconButton
    static let bodySize = canvas.body * platformScale
    static let secondarySize = canvas.small * platformScale
    static let sectionSize = canvas.label * platformScale
    static var screenTitle: Font { display(canvas.title * platformScale) }
    static func title(_ value: String, size: CGFloat = canvas.title * platformScale,
                      relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        // Inline names are operating text. Do not let the display face's minimum enlarge a row or chip.
        size >= LAAFontFamily.displayMinSize ? display(size) : .system(style)
    }
    static func chatListName(_ value: String, japaneseSize: CGFloat) -> Font { .system(size: japaneseSize) }
    static var employeeName: Font { .system(size: bodySize) }
    static var usageValue: Font { display(canvas.number * platformScale).monospacedDigit() }
    static var usageRowValue: Font { .system(size: canvas.heading * platformScale).monospacedDigit() }

    static func display(_ size: CGFloat) -> Font { LAAKit.LAAType.display(size: size) }

    enum TextRole { case body, secondary, section, rowTitle, note }
}

/// Use for system-font text at the specified base size, scaled by Dynamic Type.
private struct LAATextStyle: ViewModifier {
    let role: LAAType.TextRole
    @ScaledMetric(relativeTo: .body) private var bodySize = LAAType.bodySize
    @ScaledMetric(relativeTo: .footnote) private var secondarySize = LAAType.secondarySize
    @ScaledMetric(relativeTo: .caption) private var sectionSize = LAAType.sectionSize

    func body(content: Content) -> some View {
        switch role {
        case .body: content.font(.system(size: bodySize))
        case .secondary: content.font(.system(size: secondarySize))
        case .section: content.font(.system(size: sectionSize, weight: .semibold))
        case .rowTitle: content.font(.system(size: bodySize))
        case .note: content.font(.system(size: sectionSize, weight: .medium))
        }
    }
}

extension View {
    func laaTextStyle(_ role: LAAType.TextRole) -> some View {
        modifier(LAATextStyle(role: role))
    }
}
#endif
