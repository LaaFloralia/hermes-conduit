#if LAA_BUILD
import SwiftUI

/// The circle a task starts with, as in Things: one tap marks it done. A
/// task whose session is still running draws it dashed and refuses.
struct LAATaskCheck: View {
    let state: State
    let priority: Int
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 21
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum State: Equatable { case open, checked, blocked }

    var body: some View {
        Button(action: action) {
            ZStack {
                switch state {
                case .checked:
                    Circle().fill(LAAColor.link)
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(LAAColor.filledButtonText)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                case .open:
                    Circle().strokeBorder(priority == 1 ? LAAColor.attention : LAAColor.secondaryText.opacity(0.55),
                                          lineWidth: 1.5)
                        .background(Circle().fill(LAAColor.surface))
                case .blocked:
                    Circle().strokeBorder(LAAColor.secondaryText.opacity(0.45),
                                          style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.5]))
                }
            }
            .frame(width: size, height: size)
            // The circle is small; the target is the full 44 pt.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: state)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: state == .checked ? "完了を取り消す" : "完了にする"))
        .accessibilityHint(Text(verbatim: state == .blocked ? LAATaskRunCopy.runningReason : ""))
    }
}

/// One task. Number, title, then a quiet line of what matters: who has it,
/// how far the AI got, when it is due and how urgent it is. Nothing is drawn
/// for an empty value, so most of the owner's own rows stay one line.
struct LAATaskRow: View, Equatable {
    let row: LAATaskRowModel
    /// The genre's dot in the meta line, when the sections are not genres.
    let showsGenre: Bool
    let checked: Bool
    let selected: Bool
    let desktop: Bool
    var toggle: () -> Void = {}
    var open: () -> Void = {}

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.showsGenre == rhs.showsGenre && lhs.checked == rhs.checked
            && lhs.selected == rhs.selected && lhs.desktop == rhs.desktop
    }

    @State private var hovered = false

    private var checkState: LAATaskCheck.State {
        checked ? .checked : row.completionBlocked ? .blocked : .open
    }

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            if !row.task.isArchived {
                LAATaskCheck(state: checkState, priority: row.task.priority, action: toggle)
                    .padding(.leading, desktop ? -8 : -12)
                    .accessibilityIdentifier("work.task.check.\(row.id)")
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                    LAATaskNumberLabel(task: row.task)
                    Button(action: open) {
                        Text(verbatim: row.title)
                            .laaTextStyle(.body).fontWeight(.medium)
                            .foregroundStyle(checked ? LAAColor.secondaryText : LAAColor.text)
                            .strikethrough(checked, color: LAAColor.secondaryText)
                            .lineLimit(desktop ? 2 : 3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(LAATaskFullTitleLabel(full: row.task.title, shown: row.title))
                    .accessibilityIdentifier(desktop ? "work.task.\(row.id)" : "work.task.title.\(row.id)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                if hasMeta { meta.padding(.leading, numberIndent) }
            }
            .padding(.vertical, desktop ? 9 : 11)
        }
        .opacity(checked ? 0.72 : 1)
        .padding(.horizontal, desktop ? LAASpacing.x3 : 0)
        .background {
            if desktop {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? LAAColor.selectionFill : hovered ? LAAColor.subtleSurface.opacity(0.7) : .clear)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { if desktop { hovered = $0 } }
    }

    /// The meta line starts under the title, not under the number: the
    /// number column's width (`LAATaskNumberLabel`) and the gap after it.
    @ScaledMetric(relativeTo: .footnote) private var numberWidth: CGFloat = 34
    private var numberIndent: CGFloat { row.number == nil ? 0 : numberWidth + LAASpacing.x2 }

    private var hasMeta: Bool {
        showsGenre || row.staffName != nil || row.status != nil || row.due != nil || row.task.priority != 0
    }

    private var meta: some View {
        // Wraps rather than truncating when Dynamic Type grows.
        LAATaskMetaFlow(spacing: 10, lineSpacing: 4) {
            if showsGenre {
                HStack(spacing: 4) {
                    Circle().fill(row.genre.tint).frame(width: 7, height: 7)
                    Text(verbatim: row.genre.title).foregroundStyle(LAAColor.secondaryText)
                }
            }
            if let name = row.staffName {
                HStack(spacing: 4) {
                    if let staff = row.staff { LAAStaffStill(staff: staff, size: 17) }
                    Text(verbatim: name).foregroundStyle(LAAColor.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: "担当 \(name)"))
            }
            if let status = row.status { LAATaskStatusBadge(status: status, taskID: row.id) }
            if let due = row.due { LAATaskDueLabel(due: due) }
            if row.task.priority != 0 { LAATaskPriorityMark(value: row.task.priority) }
        }
        .laaTextStyle(.secondary)
        .lineLimit(1)
    }
}

/// A run's status: a tinted capsule that opens its session when it has one.
struct LAATaskStatusBadge: View {
    let status: LAATaskRunStatus
    let taskID: String

    var body: some View {
        let label = Text(verbatim: status.label).lineLimit(1)
            .fontWeight(status.tone == .quiet ? .regular : .semibold)
            .foregroundStyle(status.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(status.color.opacity(status.tone == .quiet ? 0.08 : 0.13), in: Capsule())
        if let session = status.sessionID {
            // The same handler the deep link uses.
            Button {
                guard let url = URL(string: "laa://work/sessions/\(session)") else { return }
                LAAWorkLinkRequest.shared.open(url)
            } label: { label }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
                .accessibilityLabel(Text(verbatim: "状態 \(status.label)。会話を開く"))
                .accessibilityIdentifier("work.task.status.\(taskID)")
        } else {
            label.accessibilityIdentifier("work.task.status.\(taskID)")
        }
    }
}

struct LAATaskDueLabel: View {
    let due: LAATaskDue

    var body: some View {
        let color: Color = switch due.tone {
        case .overdue, .today: LAAColor.attention
        case .soon: LAAColor.link
        case .later: LAAColor.secondaryText
        }
        HStack(spacing: 3) {
            Image(systemName: due.tone == .overdue ? "exclamationmark.circle" : "calendar")
                .imageScale(.small)
            Text(verbatim: due.label)
        }
        .fontWeight(due.tone == .overdue || due.tone == .today ? .semibold : .regular)
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "期限 \(due.label)\(due.tone == .overdue ? "、期限切れ" : "")"))
    }
}

/// Linear's bars: three steps for 高・中・低, a filled mark for 緊急.
struct LAATaskPriorityMark: View {
    let value: Int

    var body: some View {
        Group {
            if value == 1 {
                Image(systemName: "exclamationmark.square.fill").foregroundStyle(LAAColor.attention)
            } else {
                Image(systemName: "cellularbars", variableValue: LAATaskPriorityGlyph.level(value))
                    .foregroundStyle(LAAColor.secondaryText)
            }
        }
        .imageScale(.small)
        .accessibilityLabel(Text(verbatim: "優先度 \(LAALinearTask.priorityLabel(value))"))
    }
}

/// A section's header: the genre's mark, its name and count, and the fold.
struct LAATaskSectionHeader: View {
    let section: LAATaskSection
    let folded: Bool
    let toggle: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var mark: CGFloat = 22

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: LAASpacing.x2) {
                if let staff = section.staff {
                    LAAStaffStill(staff: staff, size: mark)
                } else if let symbol = section.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: mark * 0.5, weight: .semibold))
                        .foregroundStyle(section.tint)
                        .frame(width: mark, height: mark)
                        .background(section.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text(verbatim: section.title)
                    .laaTextStyle(.section).foregroundStyle(LAAColor.text)
                Text(verbatim: "\(section.rows.count)")
                    .laaTextStyle(.secondary).monospacedDigit()
                    .foregroundStyle(LAAColor.secondaryText)
                Spacer(minLength: LAASpacing.x2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LAAColor.secondaryText)
                    .rotationEffect(.degrees(folded ? 0 : 90))
            }
            .frame(minHeight: LAASpacing.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityLabel(Text(verbatim: "\(section.title)、\(section.rows.count)件"))
        .accessibilityValue(Text(verbatim: folded ? "畳んでいます" : "開いています"))
        .accessibilityHint(Text(verbatim: folded ? "開く" : "畳む"))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("work.tasks.section.\(section.id)")
    }
}

/// The list's controls: the range pulldown, the grouping menu, then the
/// quick filters as glass chips. Chips with nothing in them are not drawn.
struct LAATaskControls<Range: View>: View {
    @Binding var grouping: LAATaskGrouping
    @Binding var quick: LAATaskQuickFilter
    let counts: [LAATaskQuickFilter: Int]
    let showsQuick: Bool
    let allFolded: Bool
    let foldAll: (Bool) -> Void
    @ViewBuilder let range: () -> Range

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack(spacing: LAASpacing.x2) {
                range()
                Spacer(minLength: LAASpacing.x2)
                groupingMenu
            }
            if showsQuick { chips }
        }
    }

    private var groupingMenu: some View {
        Menu {
            // Plain items: inside a menu Section their identifiers do not reach UI tests.
            ForEach(LAATaskGrouping.allCases) { option in
                LAAWorkPickerItem(title: option.title, selected: option == grouping,
                                  identifier: "work.tasks.grouping.\(option.rawValue)") { grouping = option }
            }
            Divider()
            Button { foldAll(!allFolded) } label: {
                Label { Text(verbatim: allFolded ? "すべて開く" : "すべて畳む") }
                icon: { Image(systemName: allFolded ? "rectangle.expand.vertical" : "rectangle.compress.vertical") }
            }
            .accessibilityIdentifier("work.tasks.foldAll")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: grouping.symbol).font(.system(size: 12, weight: .semibold))
                Text(verbatim: grouping.title).laaTextStyle(.secondary).fontWeight(.medium)
            }
            .foregroundStyle(LAAColor.link)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .laaGlass(in: Capsule())
            .frame(minHeight: LAASpacing.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "まとめ方、\(grouping.title)"))
        .accessibilityIdentifier("work.tasks.grouping")
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LAATaskQuickFilter.allCases) { option in
                    let count = counts[option] ?? 0
                    if option == .all || count > 0 || option == quick {
                        chip(option, count: count)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func chip(_ option: LAATaskQuickFilter, count: Int) -> some View {
        let selected = quick == option
        return Button {
            withAnimation(.snappy(duration: 0.22)) { quick = selected && option != .all ? .all : option }
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: option.title).fontWeight(selected ? .semibold : .regular)
                Text(verbatim: "\(count)").monospacedDigit()
                    .foregroundStyle(selected ? LAAColor.link : LAAColor.secondaryText)
            }
            .laaTextStyle(.secondary)
            .foregroundStyle(selected ? LAAColor.link : LAAColor.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .laaGlass(in: Capsule(), selected: selected)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("work.tasks.quick.\(option.rawValue)")
    }
}

/// A wrapping row for the meta line: items flow onto a second line rather
/// than squeezing the badge or the date, and each line is centred so the
/// mascot, the capsule and the text sit on one axis.
struct LAATaskMetaFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var result: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { result.append([]); x = 0 }
            result[result.count - 1].append((index, size))
            x += size.width + spacing
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let all = lines(subviews, width: width)
        let height = all.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) } + lineSpacing * CGFloat(max(all.count - 1, 0))
        let widest = all.map { line in line.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(line.count - 1, 0)) }.max() ?? 0
        return CGSize(width: min(widest, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            let height = line.map(\.1.height).max() ?? 0
            var x = bounds.minX
            for (index, size) in line {
                subviews[index].place(at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}

/// A row that dropped its genre prefix still speaks the whole title.
private struct LAATaskFullTitleLabel: ViewModifier {
    let full: String
    let shown: String
    @ViewBuilder func body(content: Content) -> some View {
        if full == shown { content } else { content.accessibilityLabel(Text(verbatim: full)) }
    }
}
#endif
