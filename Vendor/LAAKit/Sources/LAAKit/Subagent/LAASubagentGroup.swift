import SwiftUI

/// One child's work in a subagent group.
public struct LAASubagentRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let meta: String?
    public let preview: String?
    public let status: LAAStatusMark.State

    public init(id: String, title: String, meta: String? = nil, preview: String? = nil,
                status: LAAStatusMark.State = .running) {
        self.id = id; self.title = title; self.meta = meta; self.preview = preview; self.status = status
    }
}

/// The subagent group: one `surface` block, radius 16, 1 pt rule, rows ≥ 60 pt separated by rules, each with a
/// status mark, a 13 pt title, 12 pt meta and a trailing 16 pt arrow-up-right in `accent`.
public struct LAASubagentGroup: View {
    let rows: [LAASubagentRow]
    let onOpen: (LAASubagentRow.ID) -> Void
    @Environment(\.laaPalette) private var palette

    public init(rows: [LAASubagentRow], onOpen: @escaping (LAASubagentRow.ID) -> Void) {
        self.rows = rows; self.onOpen = onOpen
    }

    public var body: some View {
        let t = LAAComponentToken.SubagentGroup.self
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Rectangle().fill(palette.rule).frame(height: LAAStroke.rule) }
                Button { onOpen(row.id) } label: {
                    HStack(alignment: .center, spacing: LAASpace.s12) {
                        LAAStatusMark(row.status)
                        VStack(alignment: .leading, spacing: LAASpace.s4) {
                            Text(row.title).laaFont(t.title, weight: .medium)
                                .foregroundStyle(palette.text).lineLimit(1)
                            if let meta = row.meta {
                                Text(meta).laaFont(t.meta).monospacedDigit()
                                    .foregroundStyle(palette.textMuted).lineLimit(1)
                            }
                            if let preview = row.preview {
                                Text(preview).laaFont(t.meta)
                                    .foregroundStyle(palette.textMuted).lineLimit(t.previewLines)
                            }
                        }
                        Spacer(minLength: 0)
                        LAAIconImage(.externalLink, size: t.trailingIconSize).foregroundStyle(palette.accent)
                    }
                    .padding(.horizontal, LAASpace.s16)
                    .padding(.vertical, LAASpace.s8)
                    .frame(minHeight: t.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("子の作業を開く")
            }
        }
        .background(RoundedRectangle(cornerRadius: t.radius, style: .continuous).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: t.radius, style: .continuous)
            .strokeBorder(palette.rule, lineWidth: t.outline))
        .clipShape(RoundedRectangle(cornerRadius: t.radius, style: .continuous))
    }
}
