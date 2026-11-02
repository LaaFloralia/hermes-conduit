#if LAA_BUILD
import SwiftUI

struct LAAUsageSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = LAAUsageState()
    var body: some View {
        LAAUsageView(state: state, onRequestSettings: { dismiss() })
    }
}
#endif
