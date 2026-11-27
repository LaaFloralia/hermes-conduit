#if LAA_BUILD
import SwiftUI
struct LAASkillsSettingsRow: View {
    var body: some View {
        NavigationLink {
            LAAWorkCatalogView().navigationTitle(Text(verbatim: "Skills"))
        } label: {
            Label { Text(verbatim: "Skills") } icon: { Image(systemName: "sparkles") }
        }
        .frame(minHeight: 44).accessibilityIdentifier("settings.skills")
    }
}
#endif
