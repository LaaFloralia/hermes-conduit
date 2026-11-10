#if LAA_BUILD
import SwiftUI

struct LAASettingsHeader: View {
    /// Nil in a window of its own, which closes from its title bar.
    let close: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: LAASpacing.x4) {
            LAAScreenHeader(title: LAACopy.settings)
            Spacer(minLength: LAASpacing.x2)
            if let close { closeButton(close) }
        }
        .padding(.horizontal, LAASpacing.horizontal)
        .padding(.vertical, LAASpacing.x2)
        .background(LAAColor.background)
    }

    @ViewBuilder private func closeButton(_ close: @escaping () -> Void) -> some View {
        if #available(iOS 26.0, *) {
            button(close).buttonStyle(.glass)
        } else {
            button(close).buttonStyle(.bordered)
        }
    }

    private func button(_ close: @escaping () -> Void) -> some View {
        Button(action: close) {
            Text(verbatim: LAACopy.done)
                .frame(minHeight: LAASpacing.minimumTouchTarget)
        }
        .tint(LAAColor.link)
        .accessibilityLabel(Text(verbatim: "設定を閉じる"))
        .accessibilityIdentifier("laa.settings.done")
    }
}
#endif
