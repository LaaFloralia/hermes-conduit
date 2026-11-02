#if LAA_BUILD
import SwiftUI

/// Conversation rendering keeps ordinary messages in order and folds each
/// consecutive run of tool calls into one compact disclosure. This is display
/// only: the Bridge response and its event order are unchanged.
enum LAAWorkToolRuns {
    struct Group: Identifiable {
        enum Kind: Equatable { case message, tools }
        let id: String
        let kind: Kind
        let messages: [LAAWorkConversationMessage]
    }

    static func groups(_ messages: [LAAWorkConversationMessage]) -> [Group] {
        var result: [Group] = []
        var pending: [LAAWorkConversationMessage] = []
        func flush() {
            guard !pending.isEmpty else { return }
            result.append(Group(id: "tools:" + pending.map(\.id).joined(separator: ","), kind: .tools, messages: pending))
            pending = []
        }
        for message in messages {
            if message.role == "tool" {
                pending.append(message)
            } else {
                flush()
                result.append(Group(id: "message:" + message.id, kind: .message, messages: [message]))
            }
        }
        flush()
        return result
    }

    static func failureCount(_ tools: [LAAWorkConversationMessage]) -> Int {
        tools.filter { isFailure($0.toolStatus) }.count
    }

    static func isFailure(_ status: String?) -> Bool {
        guard let status = status?.lowercased() else { return false }
        return ["failed", "error", "timeout", "cancelled", "canceled", "denied"].contains(status)
    }

    static func statusLabel(_ status: String?) -> String {
        switch status?.lowercased() {
        case "completed", "success", "succeeded": "完了"
        case "running", "in_progress": "実行中"
        case "failed", "error": "失敗"
        case "timeout": "時間切れ"
        case "cancelled", "canceled": "中止"
        case "denied": "拒否"
        default: status?.isEmpty == false ? status! : "状態未確認"
        }
    }
}

/// One collapsed row for a run of tool calls; each tool opens its own details.
struct LAAWorkToolRunsView: View {
    let tools: [LAAWorkConversationMessage]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: LAASpacing.x2) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LAAColor.secondaryText)
                        .accessibilityHidden(true)
                    Text(verbatim: "実行 \(tools.count)件")
                        .laaTextStyle(.secondary).fontWeight(.semibold)
                        .foregroundStyle(LAAColor.text)
                    let failures = LAAWorkToolRuns.failureCount(tools)
                    if failures > 0 {
                        Text(verbatim: "うち失敗 \(failures)件")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    }
                    Spacer(minLength: LAASpacing.x2)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LAAColor.secondaryText)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "実行 \(tools.count)件" + (LAAWorkToolRuns.failureCount(tools) > 0 ? "、うち失敗 \(LAAWorkToolRuns.failureCount(tools))件" : "")))
            .accessibilityIdentifier("work.toolRuns")

            if expanded {
                VStack(spacing: 0) {
                    ForEach(tools) { tool in
                        LAAWorkToolRunRow(tool: tool)
                        if tool.id != tools.last?.id { Divider().overlay(LAAColor.separator) }
                    }
                }
            }
        }
        .padding(.horizontal, LAASpacing.x3)
        .padding(.vertical, LAASpacing.x2)
        .background(LAAColor.subtleSurface, in: RoundedRectangle(cornerRadius: LAARadius.card))
    }
}

private struct LAAWorkToolRunRow: View {
    let tool: LAAWorkConversationMessage
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(verbatim: tool.text)
                .laaTextStyle(.secondary)
                .foregroundStyle(LAAColor.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, LAASpacing.x1)
        } label: {
            HStack(spacing: LAASpacing.x2) {
                Text(verbatim: tool.toolName ?? "ツール")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.text).lineLimit(1)
                Text(verbatim: LAAWorkToolRuns.statusLabel(tool.toolStatus))
                    .laaTextStyle(.secondary)
                    .foregroundStyle(LAAWorkToolRuns.isFailure(tool.toolStatus) ? LAAColor.attention : LAAColor.secondaryText)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 28)
        }
        .accessibilityIdentifier("work.toolRun.\(tool.id)")
    }
}
#endif
