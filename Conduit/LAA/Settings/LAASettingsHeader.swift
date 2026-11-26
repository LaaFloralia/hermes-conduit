#if LAA_BUILD
import SwiftUI

struct LAASettingsHeader: View {
    /// Nil in a window of its own, which closes from its title bar.
    let close: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: LAASpacing.x4) {
            LAAScreenHeader(title: LAACopy.settings)
            Spacer(minLength: LAASpacing.x2)
            if let close {
                LAACloseButton(glass: true, action: close)
                    .accessibilityIdentifier("laa.settings.done")
            }
        }
        .padding(.horizontal, LAASpacing.horizontal)
        .padding(.vertical, LAASpacing.x2)
        .background(LAAColor.background)
    }

}
#endif
