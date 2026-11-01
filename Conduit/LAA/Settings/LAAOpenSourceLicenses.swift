#if LAA_BUILD
import SwiftUI

/// Ship the original notices with the app and make them readable in Settings.
struct LAAOpenSourceLicenses: View {
    private var notices: String {
        guard let url = Bundle.main.url(forResource: "LAAOpenSourceNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "ライセンス文を読み込めませんでした。"
        }
        return text
    }

    var body: some View {
        DisclosureGroup {
            Text(verbatim: notices)
                .laaTextStyle(.secondary)
                .foregroundStyle(LAAColor.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, LAASpacing.x3)
                .accessibilityIdentifier("laa.licenses.text")
        } label: {
            Label(LAACopy.openSourceLicenses, systemImage: "doc.text")
                .laaTextStyle(.body)
                .foregroundStyle(LAAColor.text)
        }
        .tint(LAAColor.link)
        .padding(LAASpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
    }
}
#endif
