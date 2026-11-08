#if LAA_BUILD
import SwiftUI

/// One decision: what to decide, a short reason, the facts, then large
/// choices with the recommended one first. A session's native question uses
/// the same header and the existing session reply view underneath.
struct LAADecisionDetailView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var board: LAADecisionBoard
    @ObservedObject var drafts: ComposerDraftStore
    let onFinished: (_ removed: Bool) -> Void

    enum Choice: Hashable { case option(Int), other }

    @State private var item: LAADecision
    @State private var choice: Choice?
    @State private var note = ""
    @State private var addingNote = false
    @State private var sending = false
    @State private var failure: String?
    @State private var undelivered: String?
    @State private var sent: Bool?
    @FocusState private var noteFocused: Bool

    init(item: LAADecision, board: LAADecisionBoard, drafts: ComposerDraftStore,
         onFinished: @escaping (_ removed: Bool) -> Void) {
        _item = State(initialValue: item)
        self.board = board
        self.drafts = drafts
        self.onFinished = onFinished
        _undelivered = State(initialValue: item.deliveryFailed ? LAADecisionCopy.deliveryError(item.delivery?.error) : nil)
    }

    #if DEBUG
    /// Snapshot tests open a detail with a choice already made.
    init(item: LAADecision, board: LAADecisionBoard, drafts: ComposerDraftStore, preselected: Choice?) {
        self.init(item: item, board: board, drafts: drafts, onFinished: { _ in })
        _choice = State(initialValue: preselected)
    }
    #endif

    var body: some View {
        Group {
            if let stored = sent {
                LAADecisionCelebration(stored: stored) { onFinished(true) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: LAASpacing.x6) {
                        header
                        if item.kind == .session, let session = item.sessionId {
                            LAAWorkSessionDecision(sessionID: session, drafts: drafts) {
                                withAnimation { sent = false }
                            }
                        } else if item.answer != nil && undelivered != nil {
                            undeliveredCard
                        } else {
                            choices
                        }
                    }
                    .padding(.horizontal, LAASpacing.horizontal)
                    .padding(.top, LAASpacing.x2)
                    .padding(.bottom, LAASpacing.x8)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom) { if item.kind == .board { actionBar } }
            }
        }
        .background(LAAColor.background.ignoresSafeArea())
        .foregroundStyle(LAAColor.text)
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { onFinished(false) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text(verbatim: "閉じる"))
                    .accessibilityIdentifier("work.decision.close")
            }
        }
        .sensoryFeedback(.selection, trigger: choice)
        .sensoryFeedback(.warning, trigger: undelivered) { old, new in old == nil && new != nil }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            if let source = item.sourceLine {
                Text(verbatim: source).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(1)
            }
            Text(verbatim: item.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(LAAColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("work.decision.title")
            if !item.summary.isEmpty, item.kind == .board {
                Text(verbatim: item.summary).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            facts
        }
    }

    @ViewBuilder private var facts: some View {
        let deadline = LAADecisionDeadline.describe(item.deadline)
        if item.impact != nil || deadline != nil {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                if let impact = item.impact, !impact.isEmpty {
                    fact(icon: "arrow.triangle.branch", text: impact, color: LAAColor.secondaryText)
                }
                if let deadline {
                    fact(icon: "clock", text: deadline.text, color: deadline.urgent ? LAAColor.attention : LAAColor.secondaryText)
                }
            }
        }
    }

    private func fact(icon: String, text: String, color: Color) -> some View {
        Label { Text(verbatim: text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon) }
            .laaTextStyle(.secondary)
            .foregroundStyle(color)
    }

    // MARK: Choices

    private var choices: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            ForEach(Array(item.options.enumerated()), id: \.offset) { index, option in
                optionCard(index: index, option: option)
            }
            if item.allowOther { otherCard }
            if let choice, choice != .other {
                if addingNote {
                    noteField(prompt: "補足（任意）")
                } else {
                    Button { addingNote = true; noteFocused = true } label: {
                        Label { Text(verbatim: "補足を添える") } icon: { Image(systemName: "plus") }
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                            .frame(minHeight: LAASpacing.minimumTouchTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("work.decision.addNote")
                }
            }
        }
        .disabled(sending)
    }

    private func optionCard(index: Int, option: LAADecision.Option) -> some View {
        let selected = choice == .option(index)
        return Button { choice = .option(index) } label: {
            HStack(alignment: .center, spacing: LAASpacing.x3) {
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    if option.recommended { recommendedTag(on: selected) }
                    Text(verbatim: option.label)
                        .laaTextStyle(.body).fontWeight(.semibold)
                        .foregroundStyle(LAAColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(verbatim: detail).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                mark(selected)
            }
            .cardFrame(selected: selected)
        }
        .buttonStyle(LAADecisionPressStyle())
        .accessibilityLabel(Text(verbatim: (option.recommended ? "推奨、" : "") + option.label + (option.detail.map { "、\($0)" } ?? "")))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("work.decision.option.\(index)")
    }

    private var otherCard: some View {
        let selected = choice == .other
        return VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Button { choice = .other; addingNote = false; noteFocused = true } label: {
                HStack(spacing: LAASpacing.x3) {
                    Text(verbatim: LAADecisionCopy.other)
                        .laaTextStyle(.body).fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? LAAColor.text : LAAColor.secondaryText)
                    Spacer(minLength: 0)
                    mark(selected)
                }
                .frame(minHeight: LAASpacing.minimumTouchTarget - LAASpacing.x4)
                .contentShape(Rectangle())
            }
            .buttonStyle(LAADecisionPressStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("work.decision.other")
            if selected {
                TextField("", text: $note, prompt: Text(verbatim: "どうするかを書く"), axis: .vertical)
                    .lineLimit(2...6)
                    .laaTextStyle(.body)
                    .focused($noteFocused)
                    .accessibilityIdentifier("work.decision.note")
            }
        }
        .cardFrame(selected: selected)
    }

    private func noteField(prompt: String) -> some View {
        TextField("", text: $note, prompt: Text(verbatim: prompt), axis: .vertical)
            .lineLimit(1...5)
            .laaTextStyle(.body)
            .focused($noteFocused)
            .padding(LAASpacing.x4)
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            .overlay(RoundedRectangle(cornerRadius: LAARadius.card).strokeBorder(LAAColor.separator, lineWidth: 1))
            .accessibilityIdentifier("work.decision.note")
    }

    private func recommendedTag(on selected: Bool) -> some View {
        Label { Text(verbatim: LAADecisionCopy.recommended) } icon: { Image(systemName: "star.fill").imageScale(.small) }
            .labelStyle(.titleAndIcon)
            .laaTextStyle(.section).fontWeight(.semibold)
            .foregroundStyle(LAAColor.link)
            .padding(.horizontal, LAASpacing.x2).padding(.vertical, 2)
            .background(selected ? LAAColor.surface : LAAColor.selectionFill, in: Capsule())
            .accessibilityHidden(true)
    }

    private func mark(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? LAAColor.link : LAAColor.separator)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }

    // MARK: Delivery failed

    private var undeliveredCard: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Label { Text(verbatim: LAADecisionCopy.notDelivered) } icon: { Image(systemName: "exclamationmark.circle") }
                .laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.attention)
            if let undelivered {
                Text(verbatim: undelivered).laaTextStyle(.secondary).foregroundStyle(LAAColor.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let answer = item.answer {
                Divider().overlay(LAAColor.separator)
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: "保存した回答").laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                    Text(verbatim: answer.label).laaTextStyle(.body).fontWeight(.semibold)
                    if let note = answer.note, !note.isEmpty {
                        Text(verbatim: note).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                }
            }
        }
        .padding(LAASpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("work.decision.undelivered")
    }

    // MARK: Send

    private var canSend: Bool {
        switch choice {
        case .option?: return true
        case .other?: return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case nil: return false
        }
    }

    private var retrying: Bool { item.answer != nil && undelivered != nil }

    private var actionBar: some View {
        VStack(spacing: LAASpacing.x2) {
            if let failure {
                Text(verbatim: failure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("work.decision.failure")
            }
            Button { Task { await send() } } label: {
                HStack(spacing: LAASpacing.x2) {
                    if sending { ProgressView().tint(LAAColor.filledButtonText) }
                    Text(verbatim: sending ? "届けています" : retrying ? "もう一度届ける" : "この内容で送る")
                        .fontWeight(.semibold)
                }
                // The screen's text colour must not reach the filled button.
                .foregroundStyle(LAAColor.filledButtonText)
                .frame(maxWidth: .infinity)
            }
            .laaGlassButton(prominent: true)
            .disabled(sending || !(retrying || canSend))
            .accessibilityIdentifier("work.decision.send")
        }
        .padding(.horizontal, LAASpacing.horizontal)
        .padding(.top, LAASpacing.x2)
        .padding(.bottom, LAASpacing.x2)
    }

    private func send() async {
        guard !sending else { return }
        sending = true; failure = nil
        defer { sending = false }
        let outcome: LAADecisionBoard.Outcome
        if retrying {
            outcome = await board.retry(item, bridge: bridge)
        } else {
            guard let choice else { return }
            var index: Int?
            if case .option(let value) = choice { index = value }
            outcome = await board.answer(item, optionIndex: index,
                                         note: choice == .other || addingNote ? note : nil, bridge: bridge)
        }
        switch outcome {
        case .done(let stored):
            noteFocused = false
            withAnimation { sent = stored }
        case .notDelivered(let reason):
            if let updated = board.items.first(where: { $0.id == item.id }) { item = updated }
            withAnimation { undelivered = reason }
        case .failed(let message):
            failure = message
        }
    }
}

private extension View {
    func cardFrame(selected: Bool) -> some View {
        self
            .padding(LAASpacing.x4)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .background(selected ? LAAColor.selectionFill : LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            .overlay(RoundedRectangle(cornerRadius: LAARadius.card)
                .strokeBorder(selected ? LAAColor.link : LAAColor.separator, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: LAARadius.card))
    }
}
#endif
