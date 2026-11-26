#if LAA_BUILD
import LAAKit
import SwiftUI
import WidgetKit

@MainActor
enum LAAAppTheme {
    static let store = LAAThemeStore(appGroup: LAASelectedTheme.appGroup)

    static func select(_ id: String) {
        guard id != store.themeID else { return }
        store.select(id)
        LAASelectedTheme.shared.apply(store.themeID)
        #if DEBUG
        guard ProcessInfo.processInfo.environment["LAA_UI_TEST_THEME_SUITE"] == nil else { return }
        #endif
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Palette changes update environment values in-place, never the identity of a scene or its route.
struct LAAAppThemeModifier: ViewModifier {
    @Environment(\.scenePhase) private var phase
    private var store: LAAThemeStore { LAAAppTheme.store }

    func body(content: Content) -> some View {
        content.laaTheme(store.themeID)
            #if DEBUG
            .preferredColorScheme(ProcessInfo.processInfo.environment["LAA_UI_TEST_DARK_APPEARANCE"] == "1" ? .dark : nil)
            #endif
            .onChange(of: store.themeID, initial: true) { _, id in LAASelectedTheme.shared.apply(id) }
            .onChange(of: phase, initial: true) { _, phase in
                if phase == .active { store.reload() }
            }
    }
}

struct LAAAppearanceThemeList: View {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.laaPalette) private var palette
    private var themeID: String { LAAAppTheme.store.themeID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LAAScreenHeader(title: "Appearance", identifier: "settings.appearance.title")
                .padding(.bottom, LAASpace.s12)
            ForEach(LAAThemeSets.all) { set in
                themeRow(set)
                Rectangle().fill(palette.rule).frame(height: LAAStroke.rule).accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("settings.appearance.themes")
    }

    private func themeRow(_ set: LAAThemeSet) -> some View {
        let colors = set.colors(dark: scheme == .dark)
        let name = locale.language.languageCode?.identifier == "ja" ? set.nameJa : set.name
        let selected = themeID == set.id
        return Button { LAAAppTheme.select(set.id) } label: {
            HStack(spacing: LAASpace.s12) {
                HStack(spacing: LAASpace.s4) {
                    Circle().fill(Color(laa: colors.accent))
                    Circle().fill(Color(laa: colors.second))
                }
                .frame(width: LAAIconSize.default * LAAType.platformScale,
                       height: LAAComponentToken.statusDot * LAAType.platformScale)
                .accessibilityHidden(true)
                Text(verbatim: name).laaTextStyle(.body).foregroundStyle(palette.text)
                Spacer(minLength: LAASpace.s8)
                if selected {
                    LAAIconImage(.check, size: LAAIconSize.inline * LAAType.platformScale)
                        .foregroundStyle(palette.accent).accessibilityHidden(true)
                }
            }
            .frame(minHeight: LAASpacing.minimumRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.theme.\(set.id)")
    }
}

struct LAAAppearancePreferenceRow<Selection: View>: View {
    let title: String
    @ViewBuilder let selection: Selection

    var body: some View {
        HStack(spacing: LAASpace.s12) {
            Text(verbatim: title).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                .accessibilityHidden(true)
            Spacer(minLength: LAASpace.s8)
            selection.pickerStyle(.menu).labelsHidden().tint(LAAColor.link)
        }
        .frame(minHeight: LAASpacing.minimumRowHeight)
    }
}
#endif
