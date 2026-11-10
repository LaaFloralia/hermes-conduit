#if LAA_BUILD
import SwiftUI
struct LAASkillsSettingsRow: View {
    var body: some View {
        NavigationLink {
            LAAWorkCatalogView(kind: .skills).navigationTitle("スキル")
        } label: { Label("スキル", systemImage: "sparkles") }
        .frame(minHeight: 44).accessibilityIdentifier("settings.skills")
    }
}
#endif
