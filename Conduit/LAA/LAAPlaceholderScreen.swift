#if LAA_BUILD
import SwiftUI

/// Assets is the only remaining caller of the former placeholder.
struct LAAPlaceholderScreen: View {
    let tab: LAATab
    let onRequestSettings: () -> Void

    var body: some View {
        LAAAssetsView(onRequestSettings: onRequestSettings)
    }
}
#endif
