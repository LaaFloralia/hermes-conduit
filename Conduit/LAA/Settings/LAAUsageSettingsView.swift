#if LAA_BUILD
import SwiftUI

struct LAAUsageSettingsView: View {
    @StateObject private var state = LAAUsageState()
    var body: some View {
        LAAUsageView(state: state)
    }
}
#endif
