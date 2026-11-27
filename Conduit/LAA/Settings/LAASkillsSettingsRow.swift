#if LAA_BUILD
import SwiftUI
struct LAASkillsSettingsRow: View {
    var body: some View {
        NavigationLink {
            LAAWorkCatalogView().navigationTitle(Text(verbatim: "スキル"))
        } label: {
            // The same icon column as the other Settings rows (laaLink), so
            // the title lines up with theirs.
            HStack(spacing: LAASpacing.x3) {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(LAAColor.link)
                    .frame(width: LAASpacing.x6).accessibilityHidden(true)
                Text(verbatim: "スキル")
            }
        }
        .frame(minHeight: 44).accessibilityIdentifier("settings.skills")
    }
}
#endif
