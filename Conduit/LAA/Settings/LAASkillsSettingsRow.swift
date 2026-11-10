#if LAA_BUILD
import SwiftUI
struct LAASkillsSettingsRow: View {
    var body: some View {
        NavigationLink {
            LAAWorkCatalogView(kind: .skills).navigationTitle(Text(verbatim: "スキル"))
        } label: {
            Label { Text(verbatim: "スキル") } icon: { Image(systemName: "sparkles") }
        }
        .frame(minHeight: 44).accessibilityIdentifier("settings.skills")
    }
}
#endif
