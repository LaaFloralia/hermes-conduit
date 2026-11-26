import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The LAA bottom bar (DESIGN.md「ナビ・タブ」, tokens `tabBar.iphone`): two Liquid Glass capsules in one
// `GlassEffectContainer` — icon-only tabs on the left, the app's own icon on the right. Tapping the icon morphs
// the bar: the tab capsule shrinks to the current tab's icon and the icon's circle grows into the settings card
// (header, the settings the owner changes most as direct controls, one entry to the full settings). Tapping
// outside, the shrunk tab or VoiceOver's escape collapses it. No business logic: state and actions come in.

/// One destination of the bar. `title` is never drawn on the iPhone; it is the VoiceOver name and the Large
/// Content Viewer label.
public struct LAAGlassTab<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public let icon: LAAIcon?
    public let image: Image?
    public let selectedImage: Image?
    public var badge: Int

    /// A kit icon (Phosphor regular, fill when selected).
    public init(_ id: ID, title: String, icon: LAAIcon, badge: Int = 0) {
        self.id = id; self.title = title; self.icon = icon; self.image = nil; self.selectedImage = nil; self.badge = badge
    }

    /// The app's own artwork (regular and fill), template-rendered in `textMuted` / `accent`.
    public init(_ id: ID, title: String, image: Image, selectedImage: Image, badge: Int = 0) {
        self.id = id; self.title = title; self.icon = nil; self.image = image; self.selectedImage = selectedImage
        self.badge = badge
    }
}

/// The app shown in the right capsule and the card header.
public struct LAAAppIdentity {
    public let name: String
    public let version: String
    public let icon: Image

    public init(name: String, version: String, icon: Image) {
        self.name = name; self.version = version; self.icon = icon
    }

    /// Name and version from the main bundle; `icon` defaults to the bundle's primary app icon when it can be
    /// read (pass an explicit image when the app icon is an Icon Composer file the bundle does not expose).
    public static func main(name: String? = nil, icon: Image? = nil) -> LAAAppIdentity {
        let info = Bundle.main.infoDictionary ?? [:]
        let display = name ?? (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ""
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let version = build.isEmpty || build == short ? short : "\(short) (\(build))"
        return LAAAppIdentity(name: display, version: version, icon: icon ?? bundleIcon() ?? Image(systemName: "app"))
    }

    public static func bundleIcon() -> Image? {
        #if canImport(UIKit)
        let info = Bundle.main.infoDictionary ?? [:]
        let icons = info["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        var names = (primary?["CFBundleIconFiles"] as? [String]) ?? []
        if let name = primary?["CFBundleIconName"] as? String { names.append(name) }
        for name in names.reversed() {
            if let image = UIImage(named: name) { return Image(uiImage: image) }
        }
        return nil
        #elseif canImport(AppKit)
        return NSApplication.shared.applicationIconImage.map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}

/// Bar geometry from the tokens, for hosts that inset their content (`laaTabBarClearance`).
public enum LAAGlassTabBarLayout {
    /// The bar's height above the bottom safe area, plus one 8 pt step: the clearance scroll content needs.
    public static var contentClearance: Double {
        LAATabBarToken.height + LAATabBarToken.bottomFromSafeArea + LAASpace.s8
    }

    static func bottomPadding(safeBottom: Double) -> Double {
        max(safeBottom + LAATabBarToken.bottomFromSafeArea, LAATabBarToken.bottomMin)
    }

    static func margin(forWidth width: Double) -> Double {
        width < LAATabBarToken.compactBelowWidth ? LAATabBarToken.marginCompact : LAATabBarToken.margin
    }

    /// Bar width and tab width for `count` tabs in `available` points (margins already removed).
    static func widths(count: Int, available: Double) -> (bar: Double, item: Double) {
        let n = Double(max(count, 1))
        let fixed = LAATabBarToken.gap + LAATabBarToken.appCapsule + 2 * LAATabBarToken.inset
        let natural = fixed + n * LAATabBarToken.itemMax
        let bar = min(available, natural)
        // Below the token minimum the tabs still share the width rather than overflow (iPad split view).
        let item = min(LAATabBarToken.itemMax, max((bar - fixed) / n, 40))
        return (bar, item)
    }
}

public extension View {
    /// Places the bar over the bottom of `self` (keyboard-safe: it stays under the keyboard like a system tab
    /// bar) with an invisible layer that collapses the card on an outside tap. Hide it with `isHidden` on screens
    /// where the system bar was hidden (a conversation's composer, detail pages). Content insets are the host's:
    /// apply `laaTabBarClearance(_:)` to each tab's root.
    func laaGlassTabBar<ID: Hashable, Card: View>(
        _ tabs: [LAAGlassTab<ID>], selection: Binding<ID>, isExpanded: Binding<Bool>, isHidden: Bool = false,
        app: LAAAppIdentity, onReselect: ((ID) -> Void)? = nil, @ViewBuilder card: @escaping () -> Card
    ) -> some View {
        overlay {
            LAAGlassTabBarOverlay(tabs: tabs, selection: selection, isExpanded: isExpanded, isHidden: isHidden,
                                  app: app, onReselect: onReselect, card: card)
        }
    }

    /// Reserves the bar's height at the bottom of scrolling content so the last row clears the glass while the
    /// content still flows under it.
    func laaTabBarClearance(_ visible: Bool = true) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: visible ? LAAGlassTabBarLayout.contentClearance : 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

struct LAAGlassTabBarOverlay<ID: Hashable, Card: View>: View {
    let tabs: [LAAGlassTab<ID>]
    @Binding var selection: ID
    @Binding var isExpanded: Bool
    let isHidden: Bool
    let app: LAAAppIdentity
    let onReselect: ((ID) -> Void)?
    let card: () -> Card

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let margin = LAAGlassTabBarLayout.margin(forWidth: width)
            let available = width - 2 * margin - proxy.safeAreaInsets.leading - proxy.safeAreaInsets.trailing
            ZStack(alignment: .bottom) {
                if isExpanded && !isHidden {
                    // The outside tap: invisible, not an accessibility element (escape collapses instead).
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isExpanded = false }
                        .accessibilityHidden(true)
                        .ignoresSafeArea()
                }
                if !isHidden {
                    LAAGlassTabBar(tabs: tabs, selection: $selection, isExpanded: $isExpanded, app: app,
                                   available: available, maxCardHeight: proxy.size.height * LAATabBarToken.Card.maxHeight,
                                   onReselect: onReselect, card: card)
                        .padding(.bottom, LAAGlassTabBarLayout.bottomPadding(safeBottom: proxy.safeAreaInsets.bottom))
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .ignoresSafeArea(.keyboard)
        .onChange(of: isHidden) { _, hidden in if hidden { isExpanded = false } }
    }
}

/// The bar itself (collapsed: tabs + app icon; expanded: current tab + settings card). Usually placed through
/// `laaGlassTabBar(...)`; use directly only in previews and snapshots.
public struct LAAGlassTabBar<ID: Hashable, Card: View>: View {
    let tabs: [LAAGlassTab<ID>]
    @Binding var selection: ID
    @Binding var isExpanded: Bool
    let app: LAAAppIdentity
    let available: Double
    let maxCardHeight: Double
    let onReselect: ((ID) -> Void)?
    let card: () -> Card

    @Namespace private var space
    @LAAReduceMotion private var reduceMotion
    @LAAReduceTransparency private var reduceTransparency
    @Environment(\.laaPalette) private var palette
    @AccessibilityFocusState private var headerFocused: Bool

    public init(tabs: [LAAGlassTab<ID>], selection: Binding<ID>, isExpanded: Binding<Bool>, app: LAAAppIdentity,
                available: Double, maxCardHeight: Double = 520, onReselect: ((ID) -> Void)? = nil,
                @ViewBuilder card: @escaping () -> Card) {
        self.tabs = Array(tabs.prefix(LAATabBarToken.maxTabs))
        _selection = selection
        _isExpanded = isExpanded
        self.app = app
        self.available = available
        self.maxCardHeight = maxCardHeight
        self.onReselect = onReselect
        self.card = card
    }

    private var widths: (bar: Double, item: Double) {
        LAAGlassTabBarLayout.widths(count: tabs.count, available: available)
    }

    private var current: LAAGlassTab<ID>? { tabs.first { $0.id == selection } ?? tabs.first }

    private var morph: Animation {
        reduceMotion
            ? .easeInOut(duration: LAAMotionToken.base)
            : .spring(response: LAAMotionToken.soft.response, dampingFraction: LAAMotionToken.soft.damping)
    }

    /// Contents trade places with a short blur while the glass changes shape (the reference's feel);
    /// Reduce Motion keeps a plain cross-fade.
    private var swap: AnyTransition { reduceMotion ? .opacity : AnyTransition(.blurReplace) }

    private var press: Animation {
        reduceMotion
            ? .easeInOut(duration: LAAMotionToken.quick)
            : .spring(response: LAAMotionToken.snappy.response, dampingFraction: LAAMotionToken.snappy.damping)
    }

    public var body: some View {
        LAAGlassCluster(spacing: LAATabBarToken.mergeSpacing) {
            HStack(alignment: .bottom, spacing: LAATabBarToken.gap) {
                if isExpanded {
                    currentTab
                    settingsCard.transition(swap)
                } else {
                    tabCapsule.transition(swap)
                    appButton
                }
            }
            .frame(width: widths.bar)
        }
        .animation(morph, value: isExpanded)
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: isExpanded) { _, expanded in
            if expanded { headerFocused = true }
        }
    }

    // MARK: Collapsed

    private var tabCapsule: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
        }
        .padding(LAATabBarToken.inset)
        .frame(height: LAATabBarToken.height)
        .modifier(MorphGlass(id: "tabs", space: space, shape: Capsule(), interactive: true,
                             reduceMotion: reduceMotion, reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }

    private func tabButton(_ tab: LAAGlassTab<ID>) -> some View {
        let selected = tab.id == selection
        return Button {
            if selected {
                onReselect?(tab.id)
            } else {
                withAnimation(press) { selection = tab.id }
            }
        } label: {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: LAATabBarToken.selectionRadius, style: .continuous)
                        .fill(palette.selection)
                        .modifier(Matched(id: "selection", space: space, enabled: !reduceMotion))
                }
                tabIcon(tab, selected: selected)
                    .modifier(Matched(id: "current", space: space, enabled: selected && !reduceMotion))
                    .overlay(alignment: .topTrailing) { badge(tab.badge) }
            }
            .frame(width: widths.item, height: LAATabBarToken.height - 2 * LAATabBarToken.inset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tab.title))
        .accessibilityValue(tab.badge > 0 ? Text("\(tab.badge)") : Text(""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            tabIcon(tab, selected: selected)
            Text(tab.title)
        }
    }

    @ViewBuilder
    private func tabIcon(_ tab: LAAGlassTab<ID>, selected: Bool) -> some View {
        Group {
            if let icon = tab.icon {
                LAAIconImage(icon, size: LAATabBarToken.icon, selected: selected)
            } else if let image = selected ? tab.selectedImage : tab.image {
                image.renderingMode(.template).resizable().scaledToFit()
                    .frame(width: LAATabBarToken.icon, height: LAATabBarToken.icon)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(selected ? palette.accent : palette.textMuted)
    }

    @ViewBuilder
    private func badge(_ count: Int) -> some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: LAAPlatform.current.canvas.label, weight: .semibold).monospacedDigit())
                .foregroundStyle(palette.accent)
                .fixedSize()
                .offset(x: 10, y: -6)
                .accessibilityHidden(true)
        }
    }

    private var appButton: some View {
        Button {
            isExpanded = true
        } label: {
            appIcon(size: LAATabBarToken.appImage)
                .frame(width: LAATabBarToken.appCapsule, height: LAATabBarToken.appCapsule)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(MorphGlass(id: "app", space: space, shape: Circle(), interactive: true,
                             reduceMotion: reduceMotion, reduceTransparency: reduceTransparency))
        .accessibilityLabel(Text(app.name.isEmpty ? "Settings" : "\(app.name), Settings"))
        .accessibilityIdentifier("laa.tabbar.app")
    }

    private func appIcon(size: Double) -> some View {
        app.icon
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .modifier(Matched(id: "appIcon", space: space, enabled: !reduceMotion))
            .accessibilityHidden(true)
    }

    // MARK: Expanded

    private var currentTab: some View {
        Button {
            isExpanded = false
        } label: {
            Group {
                if let current { tabIcon(current, selected: true).modifier(Matched(id: "current", space: space, enabled: !reduceMotion)) }
            }
            .frame(width: LAATabBarToken.height, height: LAATabBarToken.height)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(MorphGlass(id: "tabs", space: space, shape: Circle(), interactive: true,
                             reduceMotion: reduceMotion, reduceTransparency: reduceTransparency))
        .accessibilityLabel(Text("Close"))
        .accessibilityIdentifier("laa.tabbar.close")
    }

    private var settingsCard: some View {
        let shape = RoundedRectangle(cornerRadius: LAATabBarToken.Card.radius, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            header
            LAACardScroll(maxHeight: maxCardHeight - LAATabBarToken.Card.headerIcon - 3 * LAATabBarToken.Card.padding) {
                VStack(alignment: .leading, spacing: 0) { card() }
                    .environment(\.laaCloseSettingsCard, { isExpanded = false })
            }
        }
        .padding(LAATabBarToken.Card.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MorphGlass(id: "app", space: space, shape: shape, interactive: false,
                             reduceMotion: reduceMotion, reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { isExpanded = false }
        .accessibilityIdentifier("laa.tabbar.card")
    }

    private var header: some View {
        HStack(spacing: LAASpace.s12) {
            appIcon(size: LAATabBarToken.Card.headerIcon)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.name)
                    .laaFont(LAAPlatform.current.canvas.heading, weight: .semibold)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                if !app.version.isEmpty {
                    Text(app.version)
                        .font(.system(size: LAAPlatform.current.canvas.label).monospacedDigit())
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, LAASpace.s8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($headerFocused)
    }
}

/// The card's rows scroll only when they do not fit (large Dynamic Type, landscape).
/// The rows' natural height is measured once per change and decides plain vs scrolling. No `ViewThatFits`:
/// inside the morphing glass (GlassEffectLayout sizing every frame of the transition) it measured both
/// candidates, the ScrollView included, on every pass and kept the main thread busy for seconds (Primula
/// 2026-11-26, iOS 27 simulator sample: GlassEntryLayout.sizeThatFits → SizeFittingLayoutComputer).
struct LAACardScroll<Content: View>: View {
    let maxHeight: Double
    @ViewBuilder let content: Content
    @State private var contentHeight: Double = 0

    var body: some View {
        let cap = max(maxHeight, LAATabBarToken.Card.row * 2)
        Group {
            if contentHeight > cap {
                ScrollView(.vertical) { measured }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: cap)
            } else {
                measured
            }
        }
    }

    private var measured: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: Double.self) { proxy in
                (proxy.size.height).rounded()
            } action: { height in
                if abs(height - contentHeight) >= 1 { contentHeight = height }
            }
    }
}

/// Glass with a morph identity. Reduce Motion drops the identity (the system materialises instead of moving
/// the shape); Reduce Transparency and pre-26 systems draw the opaque `surface` + `rule` fallback.
struct MorphGlass<S: InsettableShape>: ViewModifier {
    let id: String
    let space: Namespace.ID
    let shape: S
    let interactive: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool
    @Environment(\.laaPalette) private var palette

    func body(content: Content) -> some View {
        if !reduceTransparency, #available(iOS 26, macOS 26, watchOS 26, *) {
            content
                .glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
                .glassEffectID(reduceMotion ? nil : id, in: space)
                .glassEffectTransition(reduceMotion ? .materialize : .matchedGeometry)
        } else {
            content
                .background(shape.fill(palette.surface))
                .overlay(shape.strokeBorder(palette.rule, lineWidth: LAAStroke.rule))
                .transition(.opacity)
        }
    }
}

struct Matched: ViewModifier {
    let id: String
    let space: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.matchedGeometryEffect(id: id, in: space) } else { content }
    }
}
