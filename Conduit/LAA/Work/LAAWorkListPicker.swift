#if LAA_BUILD
import SwiftUI

/// The pulldown a Work list starts with: its label is the range the rows
/// below are in, and every choice changes this list in place. Sessions and
/// Tasks share it so the two lists read and work the same way.
struct LAAWorkListPicker<Items: View>: View {
    let title: String
    let identifier: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: LAASpacing.x1) {
                Text(verbatim: title).laaTextStyle(.section).foregroundStyle(LAAColor.text)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LAAColor.secondaryText)
            }
            .frame(minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "表示、\(title)"))
        .accessibilityIdentifier(identifier)
    }
}

/// One choice in a list pulldown, checked while it is the current one.
struct LAAWorkPickerItem: View {
    let title: String
    let selected: Bool
    var identifier = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if selected {
                Label { Text(verbatim: title) } icon: { Image(systemName: "checkmark") }
            } else {
                Text(verbatim: title)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}
#endif
