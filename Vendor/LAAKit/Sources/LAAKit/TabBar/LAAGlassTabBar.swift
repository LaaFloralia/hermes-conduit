import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The LAA bottom bar (DESIGN.md「ナビ・タブ」, tokens `tabBar.iphone`): two Liquid Glass capsules in one
// `GlassEffectContainer` — icon-only tabs on the left, LAA's profile picture on the right. Tapping it morphs
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

    func artwork(selected: Bool) -> Image? { selected ? selectedImage : image }
}

/// What the right capsule, the card header and the sidebar entry show: the owner's own name and picture
/// (D-30, 2026-11-28: "右下のタブバーのアイコンと名称はアプリのやつでなくて自分のユーザー名とアイコン"). Both come live
/// from `LAAOwnerProfileStore` (shared by every LAA app) unless the host passes them. `name` is the app's name,
/// kept for the host's own use; the bar never draws it, nor the app's icon (D-21).
public struct LAAAppIdentity {
    /// The app's name. Not drawn by the bar.
    public let name: String
    /// Shown quietly under the owner's name when non-empty.
    public let version: String
    /// The owner's picture; nil reads `LAAOwnerProfileStore` (then the initial).
    public let profile: Image?
    /// The owner's name; nil reads `LAAOwnerProfileStore` ("LAA" by default).
    public let ownerName: String?
    /// The store to read; nil is `LAAOwnerProfileStore.shared`.
    public let ownerStore: LAAOwnerProfileStore?

    public init(name: String, version: String, profile: Image?, ownerName: String? = nil,
                ownerStore: LAAOwnerProfileStore? = nil) {
        self.name = name; self.version = version; self.profile = profile
        self.ownerName = ownerName; self.ownerStore = ownerStore
    }

    @available(*, deprecated, renamed: "init(name:version:profile:)",
               message: "The bar shows the owner's picture, not the app icon (D-21); the icon is ignored.")
    public init(name: String, version: String, icon: Image) {
        self.init(name: name, version: version, profile: nil)
    }

    /// Name and version from the main bundle; the owner's name and picture from the shared store.
    public static func main(name: String? = nil, profile: Image? = nil) -> LAAAppIdentity {
        LAAAppIdentity(name: name ?? bundleName, version: bundleVersion, profile: profile)
    }

    @available(*, deprecated, renamed: "main(name:profile:)",
               message: "The bar shows the owner's picture, not the app icon (D-21); the icon is ignored.")
    public static func main(name: String? = nil, icon: Image?) -> LAAAppIdentity {
        main(name: name, profile: nil)
    }

    /// The owner's identity, live from `store` (nil: `LAAOwnerProfileStore.shared`), with the bundle's version
    /// unless one is given.
    public static func owner(store: LAAOwnerProfileStore? = nil, version: String? = nil) -> LAAAppIdentity {
        LAAAppIdentity(name: bundleName, version: version ?? bundleVersion, profile: nil, ownerStore: store)
    }

    private static var bundleName: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ""
    }

    private static var bundleVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }

    /// The bundle's primary app icon, for hosts that still need it elsewhere (not used by the bar).
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

    /// The default owner name and initial (before the owner sets their own).
    public static let ownerName = LAAOwnerProfileStore.defaultDisplayName
    static let ownerInitial = "L"

    // MARK: What is drawn (never `name`)

    @MainActor private func resolvedStore(_ store: LAAOwnerProfileStore?) -> LAAOwnerProfileStore {
        store ?? ownerStore ?? .shared
    }

    /// The name the bar draws: the explicit `ownerName`, else the store's (never the app's name).
    @MainActor public func displayedOwnerName(store: LAAOwnerProfileStore? = nil) -> String {
        if let ownerName, !ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LAAOwnerProfileStore.resolvedName(ownerName)
        }
        return resolvedStore(store).displayName
    }

    /// The picture the bar draws: the explicit `profile`, else the store's; nil draws `displayedInitial`.
    @MainActor public func displayedProfile(store: LAAOwnerProfileStore? = nil) -> Image? {
        profile ?? resolvedStore(store).avatarImage
    }

    @MainActor public func displayedInitial(store: LAAOwnerProfileStore? = nil) -> String {
        LAAOwnerProfileStore.initial(of: displayedOwnerName(store: store))
    }

    /// VoiceOver name of the right capsule and the sidebar entry.
    @MainActor public func settingsAccessibilityLabel(store: LAAOwnerProfileStore? = nil) -> String {
        "\(displayedOwnerName(store: store)), Settings"
    }
}

/// Bar geometry from the tokens, for hosts that inset their content (`laaTabBarClearance`).
public enum LAAGlassTabBarLayout {
    /// The bar's height above the bottom safe area, plus one 8 pt step, on a screen with a home indicator.
    /// Prefer `contentClearance(safeBottom:)` or `laaTabBarClearance(_:)`: without one the bar sits higher.
    public static var contentClearance: Double { contentClearance(safeBottom: 34) }

    /// The clearance scroll content needs above the bottom safe area: on a screen without a home indicator
    /// (iPhone SE) the bar keeps `bottomMin` from the edge, 24 pt higher than its home-indicator offset.
    public static func contentClearance(safeBottom: Double) -> Double {
        LAATabBarToken.height + bottomPadding(safeBottom: safeBottom) - safeBottom + LAASpace.s8
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

    // MARK: Finger slide (the track is the tab capsule; x is measured from its outer leading edge)

    /// The tab under `x`: slots of `itemWidth` start after `inset`; beyond either end, the end tab.
    public static func tabIndex(atX x: Double, count: Int, itemWidth: Double,
                                inset: Double = LAATabBarToken.inset) -> Int {
        guard count > 0, itemWidth > 0, x.isFinite else { return 0 }
        let slot = Int(((x - inset) / itemWidth).rounded(.down))
        return min(max(slot, 0), count - 1)
    }

    /// The centre of tab `index`'s slot.
    public static func centerX(ofIndex index: Int, itemWidth: Double, inset: Double = LAATabBarToken.inset) -> Double {
        inset + (Double(index) + 0.5) * itemWidth
    }

    /// Where the lens' centre follows a finger at `x`: exactly under it between the first and last slot's
    /// centres, then rubber-banded (it gives at most a quarter slot past the end, ever more stiffly).
    public static func clampedCenterX(_ x: Double, count: Int, itemWidth: Double,
                                      inset: Double = LAATabBarToken.inset) -> Double {
        let low = centerX(ofIndex: 0, itemWidth: itemWidth, inset: inset)
        let high = centerX(ofIndex: max(count, 1) - 1, itemWidth: itemWidth, inset: inset)
        guard x.isFinite else { return low }
        let limit = itemWidth * edgeGiveFraction
        func band(_ over: Double) -> Double { limit * (1 - 1 / (over / limit * 0.55 + 1)) }
        if x < low { return low - band(low - x) }
        if x > high { return high + band(x - high) }
        return x
    }

    /// The count starts this far inside the icon's trailing edge and grows outwards, so two and three digits
    /// never cover the glyph ("99+" ends about 21 pt past the icon; the next glyph is at least 29 pt away).
    public static let badgeLeadingInset: Double = 2
    /// How far past the end slot the lens may stretch, as a fraction of a slot.
    static let edgeGiveFraction = 0.25
    /// The lens while a finger is on the bar (Reduce Motion: 1, it does not grow).
    static let lensScale = (width: 1.14, height: 1.16)
    /// The coordinate space of the slide gesture: the tab capsule.
    static let trackSpace = "laa.tabbar.track"
}

public extension View {
    /// Places the bar over the bottom of `self` with an invisible layer that collapses the card on an outside
    /// tap. Hide it with `isHidden` on screens where the system bar was hidden (a conversation's composer,
    /// detail pages); while the software keyboard is shown the bar fades out by itself (tokens
    /// `tabBar.iphone.hidden`), so hosts need no keyboard observer. Content insets are the host's: apply
    /// `laaTabBarClearance(_:)` to each tab's root.
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
    /// content still flows under it. The reserve is given back while the software keyboard is shown (the bar is
    /// hidden then), so a bottom field sits on the keyboard.
    func laaTabBarClearance(_ visible: Bool = true) -> some View {
        modifier(LAATabBarClearance(visible: visible))
    }
}

private struct LAATabBarClearance: ViewModifier {
    let visible: Bool
    @State private var safeBottom: Double = 34

    func body(content: Content) -> some View {
        let keyboard = LAAKeyboardState.shared.isVisible
        return content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: visible && !keyboard
                        ? LAAGlassTabBarLayout.contentClearance(safeBottom: safeBottom) : 0)
                    // Only the keyboard's coming and going eases the reserve; a host's own `visible` stays instant.
                    .animation(.easeInOut(duration: LAAMotionToken.base), value: keyboard)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            // Read outside the inset, so the inset never feeds back into the value it is sized from.
            .onGeometryChange(for: Double.self) { $0.safeAreaInsets.bottom } action: { safeBottom = $0 }
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
    /// The keyboard came up for a field inside the open card: it must not hide the bar it belongs to.
    @State private var keyboardOwnedByCard = false

    var body: some View {
        let keyboard = LAAKeyboardState.shared.isVisible
        let hidden = isHidden || (keyboard && !isExpanded && !keyboardOwnedByCard)
        return GeometryReader { proxy in
            let width = proxy.size.width
            let margin = LAAGlassTabBarLayout.margin(forWidth: width)
            let available = width - 2 * margin - proxy.safeAreaInsets.leading - proxy.safeAreaInsets.trailing
            ZStack(alignment: .bottom) {
                if isExpanded && !hidden {
                    // The outside tap: invisible, not an accessibility element (escape collapses instead).
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isExpanded = false }
                        .accessibilityHidden(true)
                        .ignoresSafeArea()
                }
                if !hidden {
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
            // The bar leaves and returns with a fade (a push, a pop, the keyboard) instead of popping.
            .animation(.easeInOut(duration: LAAMotionToken.base), value: hidden)
        }
        .ignoresSafeArea(.keyboard)
        .onChange(of: hidden) { _, hidden in if hidden { isExpanded = false } }
        .onChange(of: keyboard) { _, shown in keyboardOwnedByCard = shown && isExpanded }
    }
}

/// The bar itself (collapsed: tabs + LAA's profile picture; expanded: current tab + settings card). Usually placed through
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
    @Environment(\.colorScheme) private var colorScheme
    @AccessibilityFocusState private var headerFocused: Bool
    /// Height of the rows pinned below the scroll (the Settings entry), measured.
    @State private var pinnedHeight: Double = 0
    /// The finger on the tab capsule (track x), the tab it went down on, the tab under it now, and whether it
    /// has left the first one. Nil x: no finger.
    @State private var dragX: Double?
    @State private var dragStartID: ID?
    @State private var dragHoverID: ID?
    @State private var dragLeftStart = false
    /// True while a touch is on the tab capsule. The system resets it when it takes the touch away (a
    /// home-indicator swipe, Control Centre, a call), which never reaches `onEnded`.
    @GestureState private var fingerDown = false

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

    /// The mark under a finger: a tight spring that keeps up with it and never jumps (the landing is `press`).
    /// Reduce Motion: the mark is simply where the finger is.
    private var follow: Animation? {
        reduceMotion
            ? nil
            : .interactiveSpring(response: LAAMotionToken.quick, dampingFraction: LAAMotionToken.snappy.damping)
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
            // The open card and the Close circle beside it are one modal scope: VoiceOver and hit-testing
            // stay inside both (the card alone as modal left Close outside it, unreachable — Console 2026-11-26).
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(isExpanded ? .isModal : [])
        }
        .animation(morph, value: isExpanded)
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: isExpanded) { _, expanded in
            guard expanded else { return }
            endSlide()
            headerFocused = true
        }
        .onChange(of: fingerDown) { _, down in
            guard !down else { return }
            // One hop later, so a normal release has run `onEnded` first. What is still set then belongs to
            // a touch the system cancelled: let go of the lens and light the selected tab again.
            Task { @MainActor in
                if !fingerDown, dragX != nil { endSlide() }
            }
        }
    }

    // MARK: Collapsed

    private var isDragging: Bool { dragX != nil }

    /// The tabs in one capsule of OS-standard Liquid Glass. A finger anywhere on it drives the selection:
    /// pressed, the mark lifts into a lens of clear glass that follows the finger across the tabs (each tab it
    /// crosses lights up with a selection tick) and lifting the finger switches to the tab under it (D-30:
    /// "スライドでタブ切り替え"). A tap is the same gesture without moving. Screen content never pages sideways
    /// (Triteleia's charts, Astrantia's canvas).
    private var tabCapsule: some View {
        let item = widths.item
        return HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabItem(tab)
            }
        }
        .padding(LAATabBarToken.inset)
        .frame(height: LAATabBarToken.height)
        .background(alignment: .leading) { selectionIndicator(item: item) }
        // laa-design:allow pill The hit shape of the OS glass tab capsule (not a fill).
        .contentShape(Capsule())
        .gesture(slide(item: item))
        .coordinateSpace(.named(LAAGlassTabBarLayout.trackSpace))
        .modifier(MorphGlass(id: "tabs", space: space, shape: Capsule(), interactive: true,
                             reduceMotion: reduceMotion, reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .sensoryFeedback(.selection, trigger: dragHoverID) { old, new in old != nil && new != nil && old != new }
    }

    private func tabID(atX x: Double, item: Double) -> ID? {
        guard !tabs.isEmpty else { return nil }
        return tabs[LAAGlassTabBarLayout.tabIndex(atX: x, count: tabs.count, itemWidth: item)].id
    }

    /// Nothing here runs inside `withAnimation`: `selection` is the host's binding, and animating its write
    /// animated every host view that depends on the selected tab. The bar animates itself (the mark in
    /// `selectionIndicator`, the icons in `tabItem`).
    private func slide(item: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(LAAGlassTabBarLayout.trackSpace))
            .updating($fingerDown) { _, down, _ in down = true }
            .onChanged { value in
                guard let hover = tabID(atX: value.location.x, item: item) else { return }
                if dragX == nil {
                    dragStartID = tabID(atX: value.startLocation.x, item: item)
                    dragLeftStart = false
                }
                dragX = value.location.x
                if hover != dragHoverID { dragHoverID = hover }
                if hover != dragStartID { dragLeftStart = true }
            }
            .onEnded { value in
                let target = tabID(atX: value.location.x, item: item) ?? selection
                let reselect = target == selection && dragStartID == selection && !dragLeftStart
                endSlide()
                if target != selection { selection = target }
                if reselect { onReselect?(target) }
            }
    }

    private func endSlide() {
        dragX = nil
        dragHoverID = nil
        dragStartID = nil
        dragLeftStart = false
    }

    /// VoiceOver, Switch Control and Full Keyboard Access activate a tab directly.
    private func activate(_ id: ID) {
        if id == selection {
            onReselect?(id)
        } else {
            selection = id
        }
    }

    private func tabItem(_ tab: LAAGlassTab<ID>) -> some View {
        let selected = tab.id == selection
        // While a finger is on the bar the tab under it is lit; otherwise the selected one.
        let lit = (dragHoverID ?? selection) == tab.id
        // Every icon keeps one identity whatever is selected (it pairs only with the Close circle's icon when
        // the bar opens). Switching the pairing on with the selection re-created both icons and flew a ghost
        // of each between the two slots on every tab change.
        return tabIcon(tab, selected: lit)
            .animation(.easeOut(duration: LAAMotionToken.quick), value: lit)
            .modifier(Matched(id: MorphIcon(id: tab.id), space: space, enabled: !reduceMotion))
            .overlay(alignment: .topTrailing) { badge(tab.badge) }
            .frame(width: widths.item, height: LAATabBarToken.height - 2 * LAATabBarToken.inset)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(tab.title))
            .accessibilityValue(tab.badge > 0 ? Text("\(tab.badge)") : Text(""))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { activate(tab.id) }
            .accessibilityShowsLargeContentViewer {
                tabIcon(tab, selected: selected)
                Text(tab.title)
            }
    }

    /// One mark for the whole capsule, so it can travel continuously: at rest a quiet translucent capsule
    /// under the selected tab (no glass of its own — glass inside the bar's glass read as a second sticker
    /// and dulled the OS-standard glass, D-30 against the first Hortensia's native bar); under a finger a
    /// lifted lens of clear glass that follows it.
    private func selectionIndicator(item: Double) -> some View {
        let index = tabs.firstIndex { $0.id == selection } ?? 0
        let center = dragX.map { LAAGlassTabBarLayout.clampedCenterX($0, count: tabs.count, itemWidth: item) }
            ?? LAAGlassTabBarLayout.centerX(ofIndex: index, itemWidth: item)
        let lifted = isDragging && !reduceMotion
        let width = item * (lifted ? LAAGlassTabBarLayout.lensScale.width : 1)
        let height = (LAATabBarToken.height - 2 * LAATabBarToken.inset)
            * (lifted ? LAAGlassTabBarLayout.lensScale.height : 1)
        return Group {
            if isDragging { lens } else { restingMark }
        }
        .frame(width: width, height: height)
        .offset(x: center - width / 2)
        // The mark's own animation, keyed on what moves it (not on the width, so a rotation does not slide it):
        // it follows the finger, lands with `press`, and returns by itself when a touch is cancelled.
        .animation(isDragging ? follow : press, value: IndicatorState(index: index, dragX: dragX, lifted: lifted))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var restingMark: some View {
        // laa-design:allow pill The selection inside the OS glass tab bar follows the system bar's capsule.
        let shape = Capsule()
        shape.fill(reduceTransparency ? palette.selection : Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
    }

    @ViewBuilder private var lens: some View {
        // laa-design:allow pill The lifted lens is the system tab bar's clear-glass capsule.
        let shape = Capsule()
        if !reduceTransparency, #available(iOS 26, macOS 26, watchOS 26, *) {
            // Materialises in place: it must not bud out of the capsule's own glass in the same container.
            shape.fill(.clear).glassEffect(Glass.clear.interactive(), in: shape)
                .glassEffectTransition(.materialize)
        } else {
            shape.fill(palette.selection)
        }
    }

    @ViewBuilder
    private func tabIcon(_ tab: LAAGlassTab<ID>, selected: Bool, size: Double = LAATabBarToken.icon) -> some View {
        Group {
            if let icon = tab.icon {
                LAAIconImage(icon, size: size, selected: selected)
            } else if let image = tab.artwork(selected: selected) {
                // Drawn as a mask: an Image here (SF Symbol or UIImage) keeps its own spoken
                // description ("Plain Text Document") beside the tab's name even when hidden.
                Rectangle().fill(.foreground)
                    .frame(width: size, height: size)
                    .mask { image.renderingMode(.template).resizable().scaledToFit() }
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
                // Anchored by its leading edge: more digits grow away from the icon, never over it.
                .alignmentGuide(.trailing) { $0[.leading] + LAAGlassTabBarLayout.badgeLeadingInset }
                .offset(y: -6)
                .accessibilityHidden(true)
        }
    }

    private var appButton: some View {
        roundButton(id: "app", visual: LAATabBarToken.appCapsule, action: { isExpanded = true }) {
            ownerAvatar(size: LAATabBarToken.appImage)
        }
        .accessibilityLabel(Text(app.settingsAccessibilityLabel()))
        .accessibilityIdentifier("laa.tabbar.app")
    }

    private func ownerAvatar(size: Double) -> some View {
        LAAProfileImage(profile: app.displayedProfile(), initial: app.displayedInitial(), size: size)
            .accessibilityHidden(true)
    }

    /// The glyph, glass, and transparent hit frame share one center. The circle is the bar's own size
    /// (`tabBar.iphone.appIcon.capsule`, the bar's height), not the generic icon button's; only the glass
    /// morphs, not the profile artwork.
    private func roundButton<Label: View>(id: String, visual: Double, action: @escaping () -> Void,
                                          @ViewBuilder label: () -> Label) -> some View {
        let hit = max(LAAPlatform.current.controlHitArea, visual)
        return Button(action: action) {
            Color.clear.frame(width: visual, height: visual)
                .overlay(alignment: .center, content: label)
                .modifier(MorphGlass(id: id, space: space, shape: Circle(), interactive: true,
                                     reduceMotion: reduceMotion, reduceTransparency: reduceTransparency))
                .frame(width: hit, height: hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: visual, height: LAATabBarToken.height, alignment: .center)
    }

    // MARK: Expanded

    private var currentTab: some View {
        roundButton(id: "tabs", visual: LAATabBarToken.height, action: { isExpanded = false }) {
            if let current {
                tabIcon(current, selected: true)
                    .modifier(Matched(id: MorphIcon(id: current.id), space: space, enabled: !reduceMotion))
            }
        }
        .accessibilityLabel(Text("Close"))
        .accessibilityIdentifier("laa.tabbar.close")
    }

    private var settingsCard: some View {
        let shape = RoundedRectangle(cornerRadius: LAATabBarToken.Card.radius, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            header
            cardRows
        }
        .environment(\.laaCloseSettingsCard, { isExpanded = false })
        .padding(LAATabBarToken.Card.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MorphGlass(id: "app", space: space, shape: shape, interactive: false,
                             reduceMotion: reduceMotion, reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { isExpanded = false }
        .accessibilityIdentifier("laa.tabbar.card")
    }

    private var rowsHeight: Double {
        maxCardHeight - LAATabBarToken.Card.headerIcon - 3 * LAATabBarToken.Card.padding
    }

    /// The rows scroll when they do not fit; the Settings entry (`LAASettingsCardEntry`) stays below the
    /// scroll, so it is always on screen at large text sizes (it was pushed under the fold at AX3, 2026-11-27).
    @ViewBuilder private var cardRows: some View {
        if #available(iOS 18, macOS 15, watchOS 11, *) {
            Group(subviews: card()) { subviews in
                let rows = subviews.filter { !$0.containerValues.laaCardPinned }
                let pinned = subviews.filter { $0.containerValues.laaCardPinned }
                LAACardScroll(maxHeight: rowsHeight - pinnedHeight) {
                    VStack(alignment: .leading, spacing: 0) { ForEach(rows) { $0 } }
                }
                VStack(alignment: .leading, spacing: 0) { ForEach(pinned) { $0 } }
                    .onGeometryChange(for: Double.self) { $0.size.height.rounded() } action: { pinnedHeight = $0 }
            }
        } else {
            LAACardScroll(maxHeight: rowsHeight) {
                VStack(alignment: .leading, spacing: 0) { card() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: LAASpace.s12) {
            ownerAvatar(size: LAATabBarToken.Card.headerIcon)
            LAASettingsCardOwnerHeading(app: app)
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
        let cap = max(maxHeight, LAAPlatform.current.canvas.rowMinHeight * 2)
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

/// The identity one tab's icon keeps between the tab capsule and the Close circle (apart from the glass ids).
private struct MorphIcon<ID: Hashable>: Hashable {
    let id: ID
}

/// What moves the selection mark: the selected slot, the finger, and whether the mark is lifted.
private struct IndicatorState: Equatable {
    let index: Int
    let dragX: Double?
    let lifted: Bool
}

/// `enabled` must be constant for a view's lifetime (Reduce Motion only): the two branches are two identities.
struct Matched<ID: Hashable>: ViewModifier {
    let id: ID
    let space: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.matchedGeometryEffect(id: id, in: space) } else { content }
    }
}

/// The owner's picture cut to a circle, or the owner's initial on the `wash` circle when there is none.
struct LAAProfileImage: View {
    let profile: Image?
    var initial: String = LAAAppIdentity.ownerInitial
    let size: Double
    @Environment(\.laaPalette) private var palette

    var body: some View {
        (profile == nil ? palette.wash : Color.clear)
            .frame(width: size, height: size)
            .overlay(alignment: .center) {
                if let profile {
                    profile.resizable().scaledToFill()
                } else {
                    Text(verbatim: initial)
                        .laaFont(LAAPlatform.current.canvas.heading, weight: .semibold)
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .clipShape(Circle())
    }
}
