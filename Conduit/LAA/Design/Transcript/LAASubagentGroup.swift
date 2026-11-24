#if LAA_BUILD
import SwiftUI

/// One quiet container per spawn batch in the transcript (ADVICE-V2 §3.5
/// "Subagent group"): `surface`, radius 16, a 1 px `rule`, rows divided by
/// 1 px rules. A row is one link that opens the child in the app; a child the
/// app cannot open draws no arrow and takes no tap.
struct LAASubagentGroup: View {
    let children: [LAAWorkingChild]
    let open: (LAAWorkingChild) -> Void
    var identifier = "transcript.subagents"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous)
        VStack(spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                if index > 0 { Rectangle().fill(LAAColor.separator).frame(height: 1) }
                LAASubagentRow(child: child, open: open, identifier: identifier + ".row")
            }
        }
        .background(LAAColor.surface, in: shape)
        .overlay { shape.strokeBorder(LAAColor.separator, lineWidth: 1) }
        .clipShape(shape)
        .frame(maxWidth: LAATranscriptMetrics.proseMeasure ?? .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Shape + title 13/500 + status word 12 in its colour + elapsed 12 tabular +
/// `arrow-up-right` 16; then `Opus 5.5 · High` and an optional three-line
/// preview, 12 muted (`critical` on failure).
struct LAASubagentRow: View {
    let child: LAAWorkingChild
    let open: (LAAWorkingChild) -> Void
    var identifier = "transcript.subagents.row"

    private static var scale: CGFloat { LAAReadingStyle.platformScale }

    var body: some View {
        Button { open(child) } label: {
            VStack(alignment: .leading, spacing: 4 * Self.scale) {
                HStack(spacing: 8 * Self.scale) {
                    Text(verbatim: child.shape).foregroundStyle(child.color)
                        .font(.system(size: 12 * Self.scale))
                    Text(verbatim: child.title)
                        .font(.system(size: 13 * Self.scale, weight: .medium))
                        .foregroundStyle(LAAColor.text)
                        .lineLimit(1)
                    Text(verbatim: "· " + child.word)
                        .font(.system(size: 12 * Self.scale, weight: .medium))
                        .foregroundStyle(child.color)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 8)
                    if child.state == .running, let startedAt = child.startedAt {
                        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                            .font(.system(size: 12 * Self.scale))
                            .monospacedDigit()
                            .foregroundStyle(LAAColor.secondaryText)
                            .fixedSize()
                    }
                    if child.resolvable {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 16 * Self.scale * 0.8, weight: .regular))
                            .frame(width: 16 * Self.scale, height: 16 * Self.scale)
                            .foregroundStyle(LAAColor.link)
                            .accessibilityHidden(true)
                    }
                }
                if let meta = child.meta, !meta.isEmpty {
                    Text(verbatim: meta)
                        .font(.system(size: 12 * Self.scale))
                        .foregroundStyle(LAAColor.secondaryText)
                        .lineLimit(1)
                }
                if let preview = child.preview, !preview.isEmpty {
                    Text(verbatim: preview)
                        .font(.system(size: 12 * Self.scale))
                        .foregroundStyle(child.state == .failed ? LAASemanticColor.critical : LAAColor.secondaryText)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 16 * Self.scale)
            .padding(.vertical, 12 * Self.scale)
            .frame(minHeight: 60 * Self.scale, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!child.resolvable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [child.title, child.word, child.meta].compactMap { $0 }.joined(separator: "、")))
        .accessibilityAddTraits(child.resolvable ? .isLink : [])
        .accessibilityIdentifier(identifier)
    }
}

/// The children of a turn as one list, for the pill's chip when there are two
/// or more.
struct LAASubagentSheet: View {
    let children: [LAAWorkingChild]
    let open: (LAAWorkingChild) -> Void
    let done: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LAASubagentGroup(children: children, open: open, identifier: "transcript.subagents.sheet")
                    .padding(LAASpacing.horizontal)
            }
            .background(LAAColor.background)
            .navigationTitle(Text(verbatim: "子 \(children.count)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String("Done"), action: done) } }
        }
        .laaSheetSize(.page)
    }
}
#endif
