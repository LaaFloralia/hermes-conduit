//
//  ChatTypography.swift
//  Conduit
//
//  Central authority for transcript-content typography (issue #85).
//
//  The chat text-size and text-style preferences are presentation settings
//  backed by UserDefaults via @AppStorage (the same pattern as
//  ComposerReturnKey). They stay on the device unless Settings > Sync
//  across devices shares them through the Conduit plugin
//  (AppState+SyncedPreferences); they never reach Hermes's own profile or
//  gateway configuration.
//
//  The selected size is a FIRST-CLASS rendering input that AUGMENTS — never
//  replaces — iOS Dynamic Type: every transcript font resolves as
//
//      system Dynamic Type size × Conduit chat text scale
//
//  so `Default` renders byte-identically to the pre-feature transcript at
//  the user's current system text size, and accessibility text sizing keeps
//  working at every position. All five values stay monotonically ordered
//  and preserve the visual hierarchy (headings above body above captions;
//  code stays monospaced) because the scale multiplies already-hierarchical
//  Dynamic Type fonts.
//
//  Only readable message/transcript content resolves fonts through this
//  type. Interface chrome — timestamps, identity labels, copy/branch/
//  read-aloud buttons, navigation, Settings, composer controls, selection
//  chrome, tool/status cards — keeps its existing typography. (A wide
//  window's chat column steps both up together: chrome through Dynamic
//  Type, transcript text through `ChatTextAppearance.widthSteps`.)
//
//  Mermaid diagrams render inside WKWebView with their own HTML/CSS and scale
//  to their width; formulas drawn in a message follow the chat body size.
//  The surrounding source cards DO use this typography (see
//  MarkupBlock/MarkupPreviewSheet/GuardedSourceCard).
//

import SwiftUI
import UIKit

/// The stepped chat text-size preference. The enum POSITION (raw value) is
/// what persists — the scale factors live in `ChatTypography` so they can be
/// tuned later without migrating stored preferences.
enum ChatTextSize: Int, CaseIterable, Equatable {
    case smallest = 0
    case smaller
    case `default`
    case larger
    case largest

    /// Relative scale applied on top of the current system Dynamic Type size.
    var scale: CGFloat {
        switch self {
        case .smallest: 0.85
        case .smaller: 0.925
        case .default: 1.00
        case .larger: 1.125
        case .largest: 1.25
        }
    }

    /// Human-readable name, used by the Settings slider's accessibility value.
    var displayName: String {
        switch self {
        case .smallest: AppLocalization.string("Smallest")
        case .smaller: AppLocalization.string("Smaller")
        case .default: AppLocalization.string("Default")
        case .larger: AppLocalization.string("Larger")
        case .largest: AppLocalization.string("Largest")
        }
    }

    /// Stable identity for typography-sensitive caches (render cache, table
    /// measurement, flow-chunk memos, code-slice identity). A different
    /// position MUST produce a different identity so no cache can serve
    /// attributed output laid out at another size.
    var cacheIdentity: String { String(rawValue) }
}

/// The chat text style preference: the typeface message text is set in.
/// Each is one of Apple's own system designs, so every language Conduit
/// ships and every Dynamic Type size is covered, as the default is. Only
/// transcript prose takes it: code stays monospaced and chrome stays SF.
enum ChatFontStyle: String, CaseIterable, Equatable {
    case standard
    case rounded
    case serif
    case mono

    var displayName: String {
        switch self {
        case .standard: AppLocalization.string("Default")
        case .rounded: AppLocalization.string("Rounded")
        case .serif: AppLocalization.string("Serif")
        case .mono: AppLocalization.string("Mono")
        }
    }

    /// The same design for SwiftUI text: list markers and the Settings
    /// preview.
    var fontDesign: Font.Design {
        switch self {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        }
    }

    var design: UIFontDescriptor.SystemDesign {
        switch self {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        }
    }
}

/// Everything transcript text renders with: the size step and the
/// typeface. Gate inputs and render caches compare and key on the whole
/// value, so neither a size nor a style change can be served stale output.
struct ChatTextAppearance: Hashable {
    var size: ChatTextSize
    var style: ChatFontStyle = .standard
    /// Text-size steps a wide window's chat column adds on top of the
    /// system's (`ReadableWidth.chatTextSteps`). Zero on a phone and
    /// beside the list.
    var widthSteps: Int = 0
    /// The system text size those steps reach: transcript fonts resolve at
    /// it, as the column's other text does through `dynamicTypeSize`.
    var widthCategory: UIContentSizeCategory?

    /// This appearance in a column that stepped its text up `steps` sizes,
    /// to `category` (the column's environment size).
    func widened(steps: Int, category: ContentSizeCategory) -> ChatTextAppearance {
        var appearance = self
        appearance.widthSteps = steps
        appearance.widthCategory = steps > 0 ? UIContentSizeCategory(category) : nil
        return appearance
    }

    /// Each size in the default typeface.
    static let smallest = ChatTextAppearance(size: .smallest)
    static let smaller = ChatTextAppearance(size: .smaller)
    static let `default` = ChatTextAppearance(size: .default)
    static let larger = ChatTextAppearance(size: .larger)
    static let largest = ChatTextAppearance(size: .largest)

    var scale: CGFloat { size.scale }

    /// The size's identity, plus the style when it isn't the default and
    /// the wide window's steps when there are any, so default keys stay
    /// what they were.
    var cacheIdentity: String {
        var identity = style == .standard ? size.cacheIdentity : "\(size.cacheIdentity)-\(style.rawValue)"
        if widthSteps > 0, let widthCategory { identity += "-w\(widthCategory.rawValue)" }
        return identity
    }
}

/// Sole authority for transcript-content font resolution. Both UIKit
/// (UIFont-returning) and SwiftUI (point-size/CGFloat-returning) consumers
/// resolve through here so settled Markdown, streaming Markdown, tables,
/// code, large documents, and source cards agree at the selected size.
enum ChatTypography {
    /// The size's preference key. Namespaced like ComposerReturnKey.
    static let preferenceKey = "conduit.chatTextSize"

    /// Initial/fallback value: existing users keep today's appearance.
    static let defaultSize: ChatTextSize = .default

    // MARK: Preference resolution

    /// Safe resolution of a persisted raw value: a missing or out-of-range
    /// value falls back to `.default` instead of trapping or clamping.
    static func resolve(rawValue: Int?) -> ChatTextSize {
        guard let rawValue, let size = ChatTextSize(rawValue: rawValue) else { return .default }
        return size
    }

    /// Reads the stored preference through UserDefaults (what @AppStorage
    /// uses), so the app and tests agree on one resolution path.
    static func stored(in defaults: UserDefaults = .standard) -> ChatTextSize {
        resolve(rawValue: defaults.object(forKey: preferenceKey) as? Int)
    }

    /// The chat text style's preference key, beside the size's.
    static let fontStylePreferenceKey = "conduit.chatFontStyle"

    /// A missing or unknown stored style (a newer app's) reads as the
    /// default.
    static func resolveStyle(rawValue: String?) -> ChatFontStyle {
        rawValue.flatMap(ChatFontStyle.init(rawValue:)) ?? .standard
    }

    // MARK: Semantic roles

    /// Transcript-content roles. Each maps to the same base Dynamic Type
    /// style the renderer used before this abstraction existed, so
    /// `.default` preserves today's exact appearance.
    enum Role: Equatable {
        /// Paragraphs, list items, quotes (with caller-applied styling
        /// handled here), callout bodies, columns, streaming text.
        case body
        /// Markdown headings by level (1...n).
        case heading(level: Int)
        /// Quote text — italic, like today.
        case quote
        /// Table header cells — bold caption.
        case tableHeader
        /// Table body cells.
        case tableBody
        /// Readable reasoning/thinking text.
        case thinking
        /// Fenced code blocks — monospaced.
        case blockCode
        /// Source text shown around rich Markdown previews (Mermaid/LaTeX
        /// render cards, guarded oversized sources) — monospaced caption.
        case sourceCode

        /// Code, which is set monospaced in every chat text style.
        var isCode: Bool {
            switch self {
            case .blockCode, .sourceCode: true
            default: false
            }
        }
    }

    // MARK: Scale

    static func scale(for size: ChatTextSize) -> CGFloat { size.scale }

    /// Scales an already-resolved (Dynamic Type aware) font. The descriptor
    /// — family, weight, symbolic traits — is preserved; only the point
    /// size grows or shrinks.
    static func scaledFont(_ base: UIFont, chatSize: ChatTextSize) -> UIFont {
        guard chatSize != .default else { return base }
        return base.withSize(base.pointSize * chatSize.scale)
    }

    /// Scales a fixed layout dimension (e.g. list-marker column widths) so
    /// chrome-adjacent content geometry keeps up with the text it hosts.
    static func dimension(_ value: CGFloat, chatSize: ChatTextSize) -> CGFloat {
        value * chatSize.scale
    }

    static func dimension(_ value: CGFloat, appearance: ChatTextAppearance) -> CGFloat {
        dimension(value, chatSize: appearance.size) * widthRatio(appearance)
    }

    /// How much a wide window's steps grow body text, from the size they
    /// started at to `widthCategory`, for geometry that keeps up with it.
    /// The steps are the ones the column took, already short of the cap.
    static func widthRatio(_ appearance: ChatTextAppearance) -> CGFloat {
        guard appearance.widthSteps > 0, let grown = appearance.widthCategory,
              let index = standardCategories.firstIndex(of: grown) else { return 1 }
        let base = standardCategories[max(0, index - appearance.widthSteps)]
        let baseSize = preferred(.body, UITraitCollection(preferredContentSizeCategory: base)).pointSize
        let grownSize = preferred(.body, UITraitCollection(preferredContentSizeCategory: grown)).pointSize
        return baseSize > 0 ? grownSize / baseSize : 1
    }

    // MARK: Wide windows

    /// The standard (not accessibility) text sizes, smallest first: the
    /// ones a wide window's steps move through.
    static let standardCategories: [UIContentSizeCategory] = [
        .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge
    ]

    /// The same sizes for SwiftUI, so the column and its transcript step
    /// through the same ones (a test holds them to one another).
    static let standardDynamicTypeSizes: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge
    ]

    /// `category` moved `steps` sizes up, stopping at the largest standard
    /// size. An accessibility size is already larger and stays as it is.
    static func boosted(_ category: UIContentSizeCategory, by steps: Int) -> UIContentSizeCategory {
        guard steps > 0, let index = standardCategories.firstIndex(of: category) else { return category }
        return standardCategories[min(standardCategories.count - 1, index + steps)]
    }

    // MARK: Font resolution

    /// Resolves a role's font at the selected chat size. The optional trait
    /// collection makes Dynamic Type behavior unit-testable; production
    /// call sites pass nil and resolve against the current system setting
    /// (identical to the pre-feature `UIFont.preferredFont` calls).
    static func font(
        for role: Role,
        chatSize: ChatTextSize,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        scaledFont(baseFont(for: role, compatibleWith: traits), chatSize: chatSize)
    }

    /// Resolves a role's font at the selected size, in the selected
    /// typeface. What every transcript view draws with.
    static func font(
        for role: Role,
        appearance: ChatTextAppearance,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        var traits = traits
        if appearance.widthSteps > 0 {
            if let given = traits {
                traits = UITraitCollection(preferredContentSizeCategory: boosted(given.preferredContentSizeCategory, by: appearance.widthSteps))
            } else if let widthCategory = appearance.widthCategory {
                traits = UITraitCollection(preferredContentSizeCategory: widthCategory)
            }
        }
        return styled(font(for: role, chatSize: appearance.size, compatibleWith: traits), role: role, style: appearance.style)
    }

    /// `font(for:appearance:)` for a view that resolves against its
    /// environment's text size, which a wide window's column has already
    /// stepped up (`readableChatColumn`): the steps aren't added twice.
    static func font(
        for role: Role,
        appearance: ChatTextAppearance,
        environmentCategory: ContentSizeCategory
    ) -> UIFont {
        var appearance = appearance
        appearance.widthSteps = 0
        appearance.widthCategory = nil
        return font(
            for: role,
            appearance: appearance,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(environmentCategory))
        )
    }

    /// `font` in `style`'s design, its size and bold or italic kept. Code
    /// roles stay monospaced whatever the style.
    static func styled(_ font: UIFont, role: Role, style: ChatFontStyle) -> UIFont {
        guard style != .standard, !role.isCode,
              let descriptor = font.fontDescriptor.withDesign(style.design) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// The unscaled (Dynamic Type only) base font for a role. Kept separate
    /// so `Default` resolution is exactly the historical font.
    static func baseFont(
        for role: Role,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        switch role {
        case .body:
            return preferred(.body, traits)
        case .heading(let level):
            return preferred(headingStyle(for: level), traits).withTraits(.traitBold)
        case .quote:
            return preferred(.body, traits).withTraits(.traitItalic)
        case .tableHeader:
            return preferred(.caption1, traits).withTraits(.traitBold)
        case .tableBody:
            return preferred(.footnote, traits)
        case .thinking:
            return preferred(.callout, traits)
        case .blockCode:
            return .monospacedSystemFont(ofSize: preferred(.footnote, traits).pointSize, weight: .regular)
        case .sourceCode:
            return .monospacedSystemFont(ofSize: preferred(.caption1, traits).pointSize, weight: .regular)
        }
    }

    /// Dynamic Type text style for a Markdown heading level — the same
    /// mapping MarkdownHeading has always used (h1 → title2 … h4+ →
    /// subheadline), bold applied above.
    static func headingStyle(for level: Int) -> UIFont.TextStyle {
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
    }

    private static func preferred(_ style: UIFont.TextStyle, _ traits: UITraitCollection?) -> UIFont {
        if let traits {
            return UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        }
        return UIFont.preferredFont(forTextStyle: style)
    }
}

// MARK: - Environment

/// Environment propagation of the selected chat text size. The default is
/// `.default` — subtrees that never receive the injection (Settings,
/// Kanban, previews, tests) keep rendering exactly as before, which is what
/// keeps this a chat-only preference rather than an app-wide one.
private struct ChatTextSizeEnvironmentKey: EnvironmentKey {
    static let defaultValue: ChatTextAppearance = .default
}

/// The text-size steps a wide window's chat column adds
/// (`readableChatColumn`), for the chat root to fold into its appearance.
private struct ChatWidthTextStepsEnvironmentKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var chatWidthTextSteps: Int {
        get { self[ChatWidthTextStepsEnvironmentKey.self] }
        set { self[ChatWidthTextStepsEnvironmentKey.self] = newValue }
    }

    /// The transcript typography this subtree renders content with, size
    /// and typeface (the name predates the typeface). Injected at the chat
    /// root; read by MarkdownText and friends.
    var chatTextSize: ChatTextAppearance {
        get { self[ChatTextSizeEnvironmentKey.self] }
        set { self[ChatTextSizeEnvironmentKey.self] = newValue }
    }
}

extension UIFont {
    /// The text style's font at `sizeCategory`, the view's environment
    /// size: a wide window's chat column steps it up (`readableChatColumn`),
    /// which the app-wide `preferredFont(forTextStyle:)` doesn't see.
    static func preferredFont(forTextStyle style: UIFont.TextStyle, in sizeCategory: ContentSizeCategory) -> UIFont {
        preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(sizeCategory)))
    }
}
