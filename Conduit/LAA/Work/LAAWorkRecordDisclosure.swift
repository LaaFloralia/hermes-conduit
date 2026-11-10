#if LAA_BUILD
import SwiftUI

/// Keeps tool traffic out of the transcript and closed until requested.
struct LAAWorkRecordDisclosure: View {
    let records: [LAAWorkConversationMessage]
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack {
                    Text(verbatim: "作業の記録 \(records.count)件")
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 13)).foregroundStyle(LAAColor.secondaryText)
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("work.session.records")
            .accessibilityValue(Text(verbatim: expanded ? "展開済み" : "閉じています"))
            if expanded { ForEach(records) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: record.toolStatus == "error" ? "実行に失敗しました" : "実行の記録")
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: record.text).font(.system(size: 13)).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            } }
        }
    }
}
#endif
