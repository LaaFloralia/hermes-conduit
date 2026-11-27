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
enum LAAColor {
    static var background: Color { selected.background }
    static var surface: Color { selected.surface }
    static var subtleSurface: Color { selected.subtleSurface }
    static var text: Color { selected.text }
    static var secondaryText: Color { selected.secondaryText }
    static var link: Color { selected.link }
    static var separator: Color { selected.separator }
    static var selectionFill: Color { selected.selectionFill }
    static var ownBubble: Color { selected.ownBubble }
    static var ownBubbleText: Color { selected.ownBubbleText }
    static var second: Color { selected.second }
    static var filledButton: Color { ownBubble }
    static var filledButtonText: Color { ownBubbleText }
    static var filledControl: Color { filledButton }
    static var filledControlText: Color { filledButtonText }
    static let positive = adaptive { dark, _ in (dark ? LAASemantic.dark : LAASemantic.light).positive }
    static let caution = adaptive { dark, _ in (dark ? LAASemantic.dark : LAASemantic.light).caution }
    static let critical = adaptive { dark, _ in (dark ? LAASemantic.dark : LAASemantic.light).critical }
    static let end = critical
    static let attention = adaptive { dark, _ in LAAThemeSets.laa.colors(dark: dark).second }
    // Fixed brand roles, independent of the selected theme. Kit v0.1.0 does not export ruleWarm.
    static let decorativeTan = Color(laa: LAAColorValues.ruleWarm)
    static let ivory = Color(laa: LAAThemeSets.laa.light.bg)
    static let rimLight = adaptive { dark, _ in dark ? LAAThemeSets.laa.light.surface : LAAColorValues.ruleWarm }

    // A role has stable identity within a theme. A theme switch publishes a
    // different Color so SwiftUI cannot reuse the previous theme's resolved
    // style when the UIKit light/dark/contrast traits have not changed.
    private static var selected: ThemeColors {
        let id = LAASelectedTheme.shared.themeID
        return themes[id] ?? defaultTheme
    }

    private static let defaultTheme = ThemeColors(LAAThemeSets.laa)
    private static let themes = Dictionary(uniqueKeysWithValues: LAAThemeSets.all.map { theme in
        (theme.id, theme.id == LAAThemeSets.defaultID ? defaultTheme : ThemeColors(theme))
    })

    private struct ThemeColors {
        let background, surface, subtleSurface, text, secondaryText, link: Color
        let separator, selectionFill, ownBubble, ownBubbleText, second: Color

        init(_ theme: LAAThemeSet) {
            func color(_ role: KeyPath<LAAThemeColors, LAARGB> & Sendable) -> Color {
                adaptive { dark, _ in theme.colors(dark: dark)[keyPath: role] }
            }
            background = color(\.bg)
            surface = color(\.surface)
            subtleSurface = color(\.wash)
            text = color(\.text)
            secondaryText = color(\.textMuted)
            link = color(\.accent)
            separator = adaptive { dark, highContrast in
                let raw = theme.colors(dark: dark)
                return highContrast ? raw.text : raw.rule
            }
            selectionFill = color(\.selection)
            ownBubble = color(\.accentFill)
            ownBubbleText = color(\.onAccent)
            second = color(\.second)
        }
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

    static func display(_ size: CGFloat) -> Font { LAAKit.LAAType.display(size: size) }

    enum TextRole { case title, heading, body, secondary, section, rowTitle, note }
}

/// Use for system-font text at the specified base size, scaled by Dynamic Type.
private struct LAATextStyle: ViewModifier {
    let role: LAAType.TextRole
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = LAAType.canvas.title * LAAType.platformScale
    @ScaledMetric(relativeTo: .title3) private var headingSize = LAAType.canvas.heading * LAAType.platformScale
    @ScaledMetric(relativeTo: .body) private var bodySize = LAAType.bodySize
    @ScaledMetric(relativeTo: .footnote) private var secondarySize = LAAType.secondarySize
    @ScaledMetric(relativeTo: .caption) private var sectionSize = LAAType.sectionSize

    func body(content: Content) -> some View {
        switch role {
        case .title: content.font(LAAType.display(titleSize))
        case .heading: content.font(.system(size: headingSize, weight: .semibold))
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
