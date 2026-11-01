#if LAA_BUILD
import SwiftUI

struct LAAWorkHub: View {
    @ObservedObject var usageState: LAAUsageState
    @Binding var showUsage: Bool
    let onRequestSettings: () -> Void

    var body: some View {
        List {
            NavigationLink { LAAWorkView(onRequestSettings: onRequestSettings) } label: { Text(verbatim: "Sessions, projects and tasks") }
            NavigationLink { LAAAssetsView(onRequestSettings: onRequestSettings) } label: { Text(verbatim: "Drive") }
            NavigationLink(isActive: $showUsage) { LAAUsageView(state: usageState, onRequestSettings: onRequestSettings) } label: { Text(verbatim: "AI usage") }
        }
        .navigationTitle("Work")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LAASettingsButton(action: onRequestSettings) } }
    }
}
#endif
