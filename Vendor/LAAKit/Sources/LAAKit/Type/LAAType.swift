import SwiftUI
#if canImport(UIKit)
import UIKit
typealias LAAPlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
typealias LAAPlatformFont = NSFont
#endif

/// The platform whose canvas row applies: iPhone (`app-390`) or Mac (`app-1280`). Mac Catalyst counts as Mac.
public enum LAAPlatform: Sendable {
    case iphone, mac
    public static var current: LAAPlatform {
        #if os(macOS) || targetEnvironment(macCatalyst)
        .mac
        #else
        .iphone
        #endif
    }
    public var canvas: LAACanvas { self == .mac ? .mac : .iphone }
}

/// Typography roles. `reading` is for prose only (Chat/Session messages, Doc body, the composer);
/// everything operable (labels, buttons, tabs, lists, numbers, widgets) uses the system `operating` faces.
public enum LAAType {
    public enum Reading: Sendable { case body, heading }
    public enum Operating: Sendable { case title, heading, body, small, label, number }

    /// Reading font: Newsreader for Latin with Shippori Mincho cascaded for Japanese (both bundled in
    /// LAAFonts). Falls back to New York + Hiragino Mincho when the bundled faces are not registered.
    public static func reading(_ role: Reading = .body, strong: Bool = false, italic: Bool = false,
                               platform: LAAPlatform = .current, scaled: Bool = true) -> Font {
        let size = readingSize(role, platform: platform)
        #if canImport(UIKit) || canImport(AppKit)
        let font = readingPlatformFont(size: size, strong: strong || role == .heading, italic: italic)
        #if !(canImport(UIKit) && !os(watchOS))
        _ = scaled
        #endif
        #if canImport(UIKit) && !os(watchOS)
        if scaled { return Font(UIFontMetrics(forTextStyle: role == .heading ? .title3 : .body).scaledFont(for: font)) }
        #endif
        return Font(font as CTFont)
        #else
        return .system(size: size, design: .serif)
        #endif
    }

    /// The reading face at an explicit point size (no Dynamic Type lookup; callers scale).
    public static func reading(size: Double, strong: Bool = false, italic: Bool = false) -> Font {
        #if canImport(UIKit) || canImport(AppKit)
        return Font(readingPlatformFont(size: size, strong: strong, italic: italic) as CTFont)
        #else
        return .system(size: size, design: .serif)
        #endif
    }

    public static func readingSize(_ role: Reading, platform: LAAPlatform = .current) -> Double {
        role == .heading ? platform.canvas.readingHeading : platform.canvas.reading
    }

    /// The fixed line box for reading text (iPhone 28, Mac 26; headings 26).
    public static func readingLine(_ role: Reading, platform: LAAPlatform = .current) -> Double {
        role == .heading ? platform.canvas.readingHeadingLine : platform.canvas.readingLine
    }

    public static func operating(_ role: Operating, platform: LAAPlatform = .current) -> Font {
        let c = platform.canvas
        switch role {
        case .title: return display(size: c.title)
        case .heading: return .system(size: c.heading, weight: .semibold)
        case .body: return .system(size: c.body)
        case .small: return .system(size: c.small)
        case .label: return .system(size: c.label, weight: .medium)
        case .number: return display(size: c.number).monospacedDigit()
        }
    }

    /// Display face (Cormorant Garamond + Shippori Mincho) for screen titles, flower names, empty states and
    /// hero numbers only, at 20 pt or more.
    public static func display(size: Double) -> Font {
        let size = max(size, LAAFontFamily.displayMinSize)
        #if canImport(UIKit) || canImport(AppKit)
        let latin = descriptor(family: LAAFontFamily.displayLatin, weight: LAAFontFamily.displayWeight, size: size * LAAFontFamily.displayLatinScale)
        let japanese = CTFontDescriptorCreateWithNameAndSize("ShipporiMincho-Medium" as CFString, size)
        let cascade = CTFontDescriptorCreateCopyWithAttributes(latin, [kCTFontCascadeListAttribute: [japanese]] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(cascade, size * LAAFontFamily.displayLatinScale, nil))
        #else
        return .system(size: size, design: .serif)
        #endif
    }

    #if canImport(UIKit) || canImport(AppKit)
    static func readingPlatformFont(size: Double, strong: Bool, italic: Bool) -> CTFont {
        let weight = strong ? LAAFontFamily.readingWeightStrong : LAAFontFamily.readingWeight
        var latin = descriptor(family: LAAFontFamily.readingLatin, weight: weight, size: size * LAAFontFamily.readingLatinScale,
                               italic: italic)
        let japaneseName = strong ? "ShipporiMincho-SemiBold" : "ShipporiMincho-Medium"
        let japanese = CTFontDescriptorCreateWithNameAndSize(japaneseName as CFString, size)
        let fallback = CTFontDescriptorCreateWithNameAndSize("HiraMinProN-W3" as CFString, size)
        latin = CTFontDescriptorCreateCopyWithAttributes(latin, [kCTFontCascadeListAttribute: [japanese, fallback]] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(latin, size * LAAFontFamily.readingLatinScale, nil)
        // Not registered (e.g. a widget or a test without LAAFonts): New York, the platform serif.
        if (CTFontCopyFamilyName(font) as String) != LAAFontFamily.readingLatin {
            return systemSerif(size: size, strong: strong, italic: italic, cascade: [japanese, fallback])
        }
        return font
    }

    static func descriptor(family: String, weight: Double, size: Double, italic: Bool = false) -> CTFontDescriptor {
        // Variable axes: wght and opsz (Newsreader 6–72; optical size follows the point size).
        let wght = 0x7767_6874, opsz = 0x6F70_737A
        var attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: family,
            kCTFontVariationAttribute: [wght: weight, opsz: min(max(size, 6), 72)],
        ]
        if italic { attributes[kCTFontTraitsAttribute] = [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitItalic.rawValue] }
        return CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
    }

    static func systemSerif(size: Double, strong: Bool, italic: Bool, cascade: [CTFontDescriptor]) -> CTFont {
        #if canImport(UIKit)
        var d = UIFont.systemFont(ofSize: size, weight: strong ? .semibold : .regular).fontDescriptor
        d = d.withDesign(.serif) ?? d
        if italic { d = d.withSymbolicTraits(.traitItalic) ?? d }
        let base = UIFont(descriptor: d, size: size) as CTFont
        #else
        var d = NSFont.systemFont(ofSize: size, weight: strong ? .semibold : .regular).fontDescriptor
        d = d.withDesign(.serif) ?? d
        if italic { d = d.withSymbolicTraits(.italic) }
        let base = (NSFont(descriptor: d, size: size) ?? NSFont.systemFont(ofSize: size)) as CTFont
        #endif
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base),
                                                                  [kCTFontCascadeListAttribute: cascade] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// Natural line height SwiftUI gives a reading line: the primary (Latin) face's metrics; the Japanese
    /// cascade does not grow the line.
    static func naturalLineHeight(size: Double, strong: Bool) -> Double {
        let font = readingPlatformFont(size: size, strong: strong, italic: false)
        return CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }
    #endif
}

/// Reading text: the reading face, the fixed line box and Latin tracking. Bold Text raises it to 600.
struct LAAReadingModifier: ViewModifier {
    let role: LAAType.Reading
    let strong: Bool
    /// iOS/watchOS/macOS 26 drop `.lineHeight(.exact)` for text with link runs; those use line spacing.
    var hasLinks = false
    @Environment(\.legibilityWeight) private var legibility
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.laaPalette) private var palette

    func body(content: Content) -> some View {
        let strong = strong || legibility == .bold
        let size = LAAType.readingSize(role)
        let line = LAAType.readingLine(role)
        let scale = LAAReadingScale.factor(dynamicType)
        let font = LAAType.reading(size: size * scale, strong: strong || role == .heading)
        let styled = content
            .font(font)
            .tracking(size * LAAFontFamily.readingTracking)
            .foregroundStyle(palette.text)
        if #available(iOS 26, macOS 26, watchOS 26, *), LAAReadingModifier.exactLineBox(hasLinks: hasLinks) {
            styled.lineHeight(.exact(points: line * scale))
        } else {
            #if canImport(UIKit) || canImport(AppKit)
            // Same box as `.exact`: the gap between lines plus half of it above the first and below the last.
            let gap = max(0, line * scale - LAAType.naturalLineHeight(size: size * scale, strong: strong))
            styled.lineSpacing(gap).padding(.vertical, gap / 2)
            #else
            styled
            #endif
        }
    }
}

extension LAAReadingModifier {
    static func exactLineBox(hasLinks: Bool) -> Bool {
        guard hasLinks else { return true }
        if #available(iOS 27, macOS 27, watchOS 27, *) { return true }
        return false
    }
}

/// How much the reading size grows with Dynamic Type (UIFontMetrics .body ratio); 1 on the Mac.
enum LAAReadingScale {
    static func factor(_ size: DynamicTypeSize) -> Double {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return 1
        #else
        switch size {
        case .xSmall: return 14.0 / 17
        case .small: return 15.0 / 17
        case .medium: return 16.0 / 17
        case .large: return 1
        case .xLarge: return 19.0 / 17
        case .xxLarge: return 21.0 / 17
        case .xxxLarge: return 23.0 / 17
        case .accessibility1: return 28.0 / 17
        case .accessibility2: return 33.0 / 17
        case .accessibility3: return 40.0 / 17
        case .accessibility4: return 47.0 / 17
        case .accessibility5: return 53.0 / 17
        @unknown default: return 1
        }
        #endif
    }
}

public extension View {
    /// Prose only: Chat/Session messages, Doc body, the composer's text. Never on buttons, labels, tabs.
    func laaReading(_ role: LAAType.Reading = .body, strong: Bool = false) -> some View {
        modifier(LAAReadingModifier(role: role, strong: strong))
    }

    /// System faces for everything operable, at the canvas sizes.
    func laaOperating(_ role: LAAType.Operating) -> some View {
        modifier(LAAOperatingModifier(role: role))
    }

    /// A system face at a token size that follows Dynamic Type (iPhone/Watch; fixed on the Mac).
    func laaFont(_ size: Double, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(LAAScaledFont(size: size, weight: weight, design: design))
    }
}

struct LAAScaledFont: ViewModifier {
    let size: Double
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.dynamicTypeSize) private var dynamicType
    func body(content: Content) -> some View {
        content.font(.system(size: size * LAAReadingScale.factor(dynamicType), weight: weight, design: design))
    }
}

struct LAAOperatingModifier: ViewModifier {
    let role: LAAType.Operating
    @Environment(\.dynamicTypeSize) private var dynamicType
    func body(content: Content) -> some View {
        let c = LAAPlatform.current.canvas
        let k = LAAReadingScale.factor(dynamicType)
        switch role {
        case .title: content.font(LAAType.display(size: c.title * k))
        case .heading: content.font(.system(size: c.heading * k, weight: .semibold))
        case .body: content.font(.system(size: c.body * k))
        case .small: content.font(.system(size: c.small * k))
        case .label: content.font(.system(size: c.label * k, weight: .medium))
        case .number: content.font(LAAType.display(size: c.number * k).monospacedDigit())
        }
    }
}
