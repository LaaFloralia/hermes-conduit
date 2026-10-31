#if LAA_BUILD
import SwiftUI

struct LAASettingsHeader: View {
    let close: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: LAASpacing.x4) {
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                Text(verbatim: LAACopy.brand)
                    .laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                Text(verbatim: LAACopy.settings)
                    .font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: LAASpacing.x2)
            closeButton
        }
        .padding(.horizontal, LAASpacing.horizontal)
        .padding(.vertical, LAASpacing.x2)
        .background(LAAColor.background)
    }

    @ViewBuilder private var closeButton: some View {
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button(action: close) {
            Text(verbatim: LAACopy.done)
                .frame(minHeight: LAASpacing.minimumTouchTarget)
        }
        .tint(LAAColor.link)
        .accessibilityLabel(Text(verbatim: "Close Settings"))
    }
}
#endif
