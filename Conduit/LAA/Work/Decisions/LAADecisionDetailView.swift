#if LAA_BUILD
import SwiftUI

/// One decision: what to decide, a short reason, the facts, then the choices
/// as rows divided by hairlines, with the recommended one first. On the Mac
/// this is the detail column beside the list; on the phone it is the sheet.
/// A session's native question uses the same header and the existing session
/// reply view underneath.
struct LAADecisionDetailView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.laaDesktop) private var laaDesktop
    @ObservedObject var board: LAADecisionBoard
    @ObservedObject var drafts: ComposerDraftStore
    /// Called with the answered record so the list can move the row to 回答済み.
    let onAnswered: ((LAADecision) -> Void)?
    let onFinished: (_ removed: Bool) -> Void

    enum Choice: Hashable { case option(Int), other }

    @State private var item: LAADecision
    @State private var choice: Choice?
    @State private var note = ""
    @State private var sending = false
    @State private var failure: String?
    @State private var undelivered: String?
    /// True when the answer just sent was stored instead of delivered.
    @State private var stored: Bool?
    @FocusState private var noteFocused: Bool

    init(item: LAADecision, board: LAADecisionBoard, drafts: ComposerDraftStore,
         onAnswered: ((LAADecision) -> Void)? = nil,
         onFinished: @escaping (_ removed: Bool) -> Void) {
        _item = State(initialValue: item)
        self.board = board
        self.drafts = drafts
        self.onAnswered = onAnswered
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
            if laaDesktop {
                scrollBody.laaReadableWidth(LAADesktopMetrics.documentWidth)
            } else {
                scrollBody.safeAreaInset(edge: .bottom) { if showsSend { actionBar } }
            }
        }
        .background { if !laaDesktop { LAAColor.background.ignoresSafeArea() } }
        .foregroundStyle(LAAColor.text)
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !laaDesktop {
                ToolbarItem(placement: .cancellationAction) {
                    Button { onFinished(false) } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text(verbatim: LAACopy.close))
                        .accessibilityIdentifier("work.decision.close")
                }
            }
        }
        .sensoryFeedback(.selection, trigger: choice)
        .sensoryFeedback(.warning, trigger: undelivered) { old, new in old == nil && new != nil }
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                header
                if item.kind == .session, let session = item.sessionId {
                    LAAWorkSessionDecision(sessionID: session, drafts: drafts) {
                        if laaDesktop { Task { await board.load(bridge) } } else { onFinished(false) }
                    }
                } else if let answer = item.answer {
                    if undelivered != nil { undeliveredBlock }
                    answerBlock(answer)
                    if laaDesktop, showsSend { desktopAction }
                } else {
                    choices
                    if laaDesktop { desktopAction }
                }
            }
            .padding(.horizontal, laaDesktop ? LAASpacing.x8 : LAASpacing.horizontal)
            .padding(.top, laaDesktop ? LAASpacing.x6 : LAASpacing.x2)
            .padding(.bottom, LAASpacing.x8)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Header

    /// "J3 · S5 · <conversation>": the decision's own number leads, like a task's T12.
    private var headerMeta: String? {
        let parts = [item.kind == .board ? LAAWorkRef.display(item.ref) : nil, item.sourceLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            if let answer = item.answer { answeredLine(answer) }
            if let source = headerMeta {
                Text(verbatim: source).laaTextStyle(.secondary).monospacedDigit().foregroundStyle(LAAColor.secondaryText).lineLimit(1)
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

    /// The one line that replaces the old celebration. It only advances a
    /// just-sent answer on the phone; an answered record stays put.
    private func answeredLine(_ answer: LAADecision.Answer) -> some View {
        let finish: (() -> Void)? = stored != nil && !laaDesktop ? { onFinished(false) } : nil
        return LAADecisionCelebration(stored: stored == true,
                                      answeredAt: LAAWorkFreshness.date(answer.answeredAt),
                                      onFinished: finish)
    }

    @ViewBuilder private var facts: some View {
        let deadline = LAADecisionDeadline.describe(item.deadline)
        if item.answer == nil, item.impact != nil || deadline != nil {
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
            VStack(spacing: 0) {
                ForEach(Array(item.options.enumerated()), id: \.offset) { index, option in
                    if index > 0 { Rectangle().fill(LAAColor.separator).frame(height: 1) }
                    optionRow(index: index, option: option)
                }
            }
            if item.allowOther { freeAnswer }
        }
        .disabled(sending)
    }

    /// The free answer used to sit behind a "その他（自由記入）" card: with a
    /// long decision it stayed below the fold and the owner had to guess it
    /// existed. It is now an always-visible field under the choices; writing
    /// in it selects その他, and it is sent as optionIndex null with the note.
    private var freeAnswer: some View {
        let selected = choice == .other
        return VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: LAADecisionCopy.otherTitle)
                .laaTextStyle(.section).fontWeight(.semibold)
                .foregroundStyle(LAAColor.text)
                .accessibilityAddTraits(.isHeader)
            TextField("", text: $note, prompt: Text(verbatim: "どうするかを書く"), axis: .vertical)
                .lineLimit(2...6)
                .laaTextStyle(.body)
                .focused($noteFocused)
                .padding(LAASpacing.x3)
                .background(LAAColor.subtleSurface, in: RoundedRectangle(cornerRadius: LAARadius.selectionChip))
                .overlay(RoundedRectangle(cornerRadius: LAARadius.selectionChip)
                    .strokeBorder(selected ? LAAColor.link : LAAColor.separator, lineWidth: selected ? 1.5 : 1))
                .accessibilityLabel(Text(verbatim: LAADecisionCopy.otherTitle))
                .accessibilityIdentifier("work.decision.note")
        }
        .padding(.top, LAASpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(LAAColor.separator).frame(height: 1) }
        .accessibilityIdentifier("work.decision.otherSection")
        .onChange(of: note) { _, value in
            let written = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if written { choice = .other }
            else if choice == .other { choice = nil }
        }
    }

    private func optionRow(index: Int, option: LAADecision.Option) -> some View {
        let selected = choice == .option(index)
        return Button { choice = .option(index) } label: {
            HStack(alignment: .center, spacing: LAASpacing.x3) {
                mark(selected)
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    if option.recommended {
                        Text(verbatim: LAADecisionCopy.recommended)
                            .laaTextStyle(.section).fontWeight(.semibold)
                            .foregroundStyle(LAAColor.link)
                            .accessibilityHidden(true)
                    }
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
            }
            .padding(.horizontal, LAASpacing.x3)
            .padding(.vertical, LAASpacing.x3)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .background(selected ? LAAColor.selectionFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: LAASpacing.x2))
            .contentShape(RoundedRectangle(cornerRadius: LAASpacing.x2))
        }
        .buttonStyle(LAADecisionPressStyle())
        .accessibilityLabel(Text(verbatim: (option.recommended ? "推奨、" : "") + option.label
                                 + (option.detail.map { "、\($0)" } ?? "")))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("work.decision.option.\(index)")
    }

    private func mark(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .imageScale(.medium)
            .foregroundStyle(selected ? LAAColor.link : LAAColor.secondaryText)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }

    // MARK: Answered

    private func answerBlock(_ answer: LAADecision.Answer) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: "回答").laaTextStyle(.section).fontWeight(.semibold)
                .foregroundStyle(LAAColor.secondaryText)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: answer.label).laaTextStyle(.body).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            if let note = answer.note, !note.isEmpty {
                Text(verbatim: note).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, LAASpacing.x3)
        .overlay(alignment: .top) { Rectangle().fill(LAAColor.separator).frame(height: 1) }
    }

    private var undeliveredBlock: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: LAADecisionCopy.notDelivered)
                .laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.attention)
            if let undelivered {
                Text(verbatim: undelivered).laaTextStyle(.secondary).foregroundStyle(LAAColor.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// One primary action, and only while there is something to send.
    private var showsSend: Bool { item.kind == .board && (item.answer == nil || retrying) }

    private var sendTitle: String {
        sending ? "届けています" : retrying ? "届け直す" : "この内容で返す"
    }

    private var actionBar: some View {
        VStack(spacing: LAASpacing.x2) {
            failureText
            Button { Task { await send() } } label: {
                sendLabel(fullWidth: true)
            }
            .laaGlassButton(prominent: true)
            .disabled(sending || !(retrying || canSend))
            .accessibilityIdentifier("work.decision.send")
        }
        .padding(.horizontal, LAASpacing.horizontal)
        .padding(.top, LAASpacing.x2)
        .padding(.bottom, LAASpacing.x2)
    }

    /// On the Mac the action sits at the end of the page, not in a bar.
    private var desktopAction: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            failureText
            HStack(spacing: LAASpacing.x3) {
                Spacer(minLength: 0)
                Button { Task { await send() } } label: { sendLabel(fullWidth: false) }
                    .laaGlassButton(prominent: true)
                    .disabled(sending || !(retrying || canSend))
                    .accessibilityIdentifier("work.decision.send")
            }
        }
    }

    @ViewBuilder private var failureText: some View {
        if let failure {
            Text(verbatim: failure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("work.decision.failure")
        }
    }

    private func sendLabel(fullWidth: Bool) -> some View {
        HStack(spacing: LAASpacing.x2) {
            if sending { Text(verbatim: "送信中").foregroundStyle(LAAColor.filledButtonText) }
            Text(verbatim: sendTitle).fontWeight(.semibold)
        }
        // The screen's text colour must not reach the filled button.
        .foregroundStyle(LAAColor.filledButtonText)
        .frame(maxWidth: fullWidth ? .infinity : nil)
    }

    private func send() async {
        guard !sending else { return }
        sending = true; failure = nil
        defer { sending = false }
        if retrying {
            switch await board.retry(item, bridge: bridge) {
            case .done:
                noteFocused = false
                withAnimation { stored = false }
                onAnswered?(LAADecisionBoardView.delivered(item))
            case .notDelivered(let reason):
                if let updated = board.items.first(where: { $0.id == item.id }) { item = updated }
                withAnimation { undelivered = reason }
            case .failed(let message):
                failure = message
            }
            return
        }
        guard let choice else { return }
        var index: Int?
        if case .option(let value) = choice { index = value }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = await board.answer(item, optionIndex: index, note: text.isEmpty ? nil : text, bridge: bridge)
        switch outcome {
        case .done(let wasStored):
            noteFocused = false
            let answered = Self.answered(item, optionIndex: index,
                                         label: index.map { item.options[$0].label } ?? text,
                                         note: index == nil ? nil : (text.isEmpty ? nil : text))
            item = answered
            withAnimation { stored = wasStored }
            onAnswered?(answered)
        case .notDelivered(let reason):
            if let updated = board.items.first(where: { $0.id == item.id }) { item = updated }
            withAnimation { undelivered = reason }
        case .failed(let message):
            failure = message
        }
    }

    /// The record as the Bridge keeps it after an answer: `label` is the chosen
    /// option or the free text, and a free answer keeps `optionIndex` null.
    static func answered(_ item: LAADecision, optionIndex: Int?, label: String, note: String?) -> LAADecision {
        LAADecision(kind: item.kind, id: item.id, ref: item.ref, status: "answered", title: item.title,
                    summary: item.summary, options: item.options, allowOther: item.allowOther, impact: item.impact,
                    deadline: item.deadline, source: item.source, sourceRef: item.sourceRef, createdAt: item.createdAt,
                    answer: .init(optionIndex: optionIndex, label: label, note: note,
                                  answeredAt: ISO8601DateFormatter().string(from: Date())),
                    delivery: item.delivery, sessionId: item.sessionId)
    }
}
#endif
