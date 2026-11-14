#if LAA_BUILD
import SwiftUI

/// The Work hub's board: one row per thing waiting for the owner. The title
/// says what to decide; one quiet line adds source, deadline and the
/// recommended choice. On the Mac the list keeps its column and the chosen
/// decision opens beside it instead of in a sheet.
struct LAADecisionBoardView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.laaDesktop) private var laaDesktop
    @ObservedObject var board: LAADecisionBoard
    @ObservedObject var drafts: ComposerDraftStore
    @State private var selected: LAADecision?
    /// The decision shown in the Mac detail column.
    @State private var selectedID: String?
    /// Answers sent from this screen. A delivered answer leaves the board, so
    /// the list keeps its own record for the 回答済み section and the detail.
    @State private var answered: [LAADecision] = []
    @State private var retrying: String?
    @State private var retryFailure: [String: String] = [:]
    @State private var retried = 0
    @FocusState private var listFocused: Bool
    #if DEBUG
    /// Snapshots draw the list without a network read.
    var loadsOnAppear = true
    #endif

    var body: some View {
        content
            .background(LAAColor.background)
            .tint(LAAColor.link)
            .refreshable { await board.load(bridge) }
            .task(id: bridge.revision) {
                #if DEBUG
                guard loadsOnAppear else { return }
                #endif
                await board.refreshIfStale(bridge)
            }
            .onChange(of: board.linkedID, initial: true) { _, _ in openLinked() }
            .onChange(of: board.items) { _, _ in openLinked() }
            .onChange(of: rowIDs, initial: true) { _, ids in selectFirstIfNeeded(ids) }
            .sheet(item: $selected) { item in
                NavigationStack {
                    LAADecisionDetailView(item: item, board: board, drafts: drafts, onAnswered: remember) { _ in
                        selected = nil
                    }
                }
                .environmentObject(bridge)
                .laaSheetSize(.page)
            }
            .sensoryFeedback(.success, trigger: retried)
            .accessibilityIdentifier("work.decisions")
    }

    @ViewBuilder private var content: some View {
        switch board.phase {
        case .unsupported:
            message(title: LAADecisionCopy.unsupported, detail: LAADecisionCopy.unsupportedDetail,
                    identifier: "work.decisions.unsupported")
        case .failed(let text) where board.items.isEmpty:
            message(title: "判断ボードを読めません", detail: text,
                    identifier: "work.decisions.failure", retry: true)
        case .idle where board.loading:
            LAALoadingDots().padding(20)
        default:
            if openItems.isEmpty && answeredItems.isEmpty && !board.loading {
                message(title: LAADecisionCopy.empty, identifier: "work.decisions.empty")
            } else if laaDesktop {
                desktopBoard
            } else {
                phoneList
            }
        }
    }

    // MARK: Rows

    private var openItems: [LAADecision] { board.items.filter { $0.answer == nil } }

    /// Delivered here first, then the ones the Bridge kept after a failed
    /// delivery; both carry an answer.
    private var answeredItems: [LAADecision] {
        var seen = Set<String>()
        return (answered + board.items.filter { $0.answer != nil }).filter { seen.insert($0.id).inserted }
    }

    private var rowIDs: [String] { (openItems + answeredItems).map(\.id) }

    private var selectedItem: LAADecision? {
        guard let selectedID else { return nil }
        return answered.first { $0.id == selectedID } ?? board.items.first { $0.id == selectedID }
    }

    private var phoneList: some View {
        List {
            if case .failed(let text) = board.phase {
                Section {
                    Text(verbatim: text).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    Button { Task { await board.load(bridge) } } label: { Text(verbatim: "再試行") }
                }
            }
            if !openItems.isEmpty {
                Section {
                    ForEach(openItems) { item in
                        row(item)
                            .listRowBackground(LAAColor.surface)
                    }
                } header: {
                    sectionText("未回答", count: openItems.count)
                }
            }
            if !answeredItems.isEmpty {
                Section {
                    ForEach(answeredItems) { item in
                        row(item)
                            .listRowBackground(LAAColor.surface)
                    }
                } header: {
                    sectionText("回答済み")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var desktopBoard: some View {
        LAAMacListDetail {
            VStack(spacing: 0) {
                HStack(spacing: LAASpacing.x2) {
                    if board.loading && board.items.isEmpty { LAALoadingDots() }
                    Spacer(minLength: 0)
                    Button { Task { await board.load(bridge) } } label: { Image(systemName: "arrow.clockwise") }
                        .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                        .accessibilityLabel(Text(verbatim: "再読み込み"))
                        .macTooltip("Reload")
                        .disabled(board.loading)
                }
                .padding(.horizontal, LAASpacing.x3)
                .padding(.vertical, LAASpacing.x2)
                Rectangle().fill(LAAColor.separator).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if case .failed(let text) = board.phase {
                            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                                Text(verbatim: text).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                                Button { Task { await board.load(bridge) } } label: { Text(verbatim: "再試行") }
                            }
                            .padding(LAASpacing.x3)
                        }
                        if !openItems.isEmpty {
                            sectionTitle("未回答", count: openItems.count)
                            ForEach(openItems) { item in
                                row(item, selected: selectedID == item.id)
                            }
                        }
                        if !answeredItems.isEmpty {
                            sectionTitle("回答済み")
                            ForEach(answeredItems) { item in
                                row(item, selected: selectedID == item.id)
                            }
                        }
                    }
                    .padding(.vertical, LAASpacing.x2)
                }
            }
            .background(LAAColor.background)
            .focusable()
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.return) { if selectedID == nil { selectedID = rowIDs.first }; return .handled }
            .onKeyPress(.escape) { selectedID = nil; return .handled }
            .accessibilityIdentifier("work.decisions.list")
        } detail: {
            if let item = selectedItem {
                LAADecisionDetailView(item: item, board: board, drafts: drafts, onAnswered: remember) { _ in }
                    // A retry that went through is a new record: the screen
                    // starts over, so no stale failure line can stay.
                    .id(item.id + ":" + (item.delivery?.state ?? "-"))
            } else {
                Text(verbatim: "判断を選んでください")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("work.decisions.desktop")
    }

    /// `未回答 2`. The Mac label starts where a row's title does; the phone's
    /// List styles its own section headers.
    private func sectionText(_ title: String, count: Int? = nil) -> Text {
        Text(verbatim: count.map { "\(title) \($0)" } ?? title)
    }

    private func sectionTitle(_ title: String, count: Int? = nil) -> some View {
        sectionText(title, count: count)
            .laaTextStyle(.section).fontWeight(.semibold)
            .foregroundStyle(LAAColor.secondaryText)
            .padding(.horizontal, LAASpacing.x2 + LAASpacing.x3)
            .padding(.top, LAASpacing.x3)
            .padding(.bottom, LAASpacing.x1)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: LAADecision, selected: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            LAADecisionRow(item: item, meta: metaLine(item), selected: selected,
                           desktop: laaDesktop, open: { show(item) })
                .contextMenu { rowMenu(item) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: LAADecisionCopy.accessibilityLabel(item)))
                .accessibilityAddTraits(.isButton)
                // An answered row is its own element: the open row's id goes
                // with the answer it no longer waits for.
                .accessibilityIdentifier(item.answer == nil ? "work.decision.\(item.id)"
                                                            : "work.decision.answered.\(item.id)")
            if item.deliveryFailed { undelivered(item) }
        }
        .padding(.horizontal, laaDesktop ? LAASpacing.x2 : 0)
    }

    @ViewBuilder private func rowMenu(_ item: LAADecision) -> some View {
        Button { show(item) } label: { Text(verbatim: "開く") }
        if item.deliveryFailed {
            Button { Task { await retry(item) } } label: { Text(verbatim: "届け直す") }
        }
    }

    /// Source and deadline, or how the answer went back; no summary of what
    /// the screen already says.
    private func metaLine(_ item: LAADecision) -> AttributedString {
        if let answer = item.answer { return Self.answeredLine(item, answer: answer) }
        return Self.meta(item) ?? AttributedString()
    }

    private func undelivered(_ item: LAADecision) -> some View {
        HStack(spacing: LAASpacing.x3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: LAADecisionCopy.notDelivered).fontWeight(.semibold).foregroundStyle(LAAColor.attention)
                Text(verbatim: retryFailure[item.id] ?? LAADecisionCopy.deliveryError(item.delivery?.error))
                    .foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(2)
            }
            .laaTextStyle(.secondary)
            Spacer(minLength: 0)
            Button { Task { await retry(item) } } label: {
                Group {
                    if retrying == item.id { Text(verbatim: "送信中") }
                    else {
                        Label { Text(verbatim: "届け直す") } icon: { Image(systemName: "arrow.clockwise") }
                            .laaTextStyle(.secondary).fontWeight(.semibold).foregroundStyle(LAAColor.link)
                    }
                }
                .padding(.horizontal, LAASpacing.x3)
                .frame(minHeight: LAASpacing.minimumTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(LAADecisionPressStyle())
            .disabled(retrying != nil)
            .accessibilityIdentifier("work.decision.retry.\(item.id)")
        }
        .padding(.leading, laaDesktop ? LAASpacing.x3 : 0)
        .padding(.bottom, LAASpacing.x1)
    }

    private func message(title: String, detail: String? = nil, identifier: String, retry: Bool = false) -> some View {
        VStack(spacing: LAASpacing.x3) {
            Text(verbatim: title)
                .laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
                .multilineTextAlignment(.center)
            if let detail {
                Text(verbatim: detail)
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if retry {
                Button { Task { await board.load(bridge) } } label: { Text(verbatim: "再試行") }
                    .laaGlassButton()
            }
        }
        .padding(LAASpacing.x8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Selection

    private func show(_ item: LAADecision) {
        if laaDesktop {
            // A record read from a link is not in the list yet; keep it so the
            // detail column has something to show.
            if !board.items.contains(where: { $0.id == item.id }) { store(item) }
            selectedID = item.id
        } else {
            selected = item
        }
    }

    private func store(_ item: LAADecision) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35)) {
            answered.removeAll { $0.id == item.id }
            answered.insert(item, at: 0)
        }
    }

    /// An answer that left for the conversation: the row moves to 回答済み.
    private func remember(_ item: LAADecision) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35)) {
            answered.removeAll { $0.id == item.id }
            answered.insert(item, at: 0)
            board.remove(item.id)
        }
    }

    private func selectFirstIfNeeded(_ ids: [String]) {
        guard laaDesktop else { return }
        if let selectedID, ids.contains(selectedID) { return }
        selectedID = ids.first
    }

    private func move(_ delta: Int) {
        let ids = rowIDs
        guard !ids.isEmpty else { return }
        guard let current = selectedID.flatMap(ids.firstIndex(of:)) else {
            selectedID = delta > 0 ? ids.first : ids.last
            return
        }
        selectedID = ids[min(max(current + delta, 0), ids.count - 1)]
    }

    private func openLinked() {
        #if DEBUG
        guard loadsOnAppear else { return }
        #endif
        guard let id = board.linkedID, board.phase != .idle else { return }
        if let item = board.items.first(where: { $0.id == id }) {
            board.linkedID = nil
            show(item)
        } else if board.phase == .loaded, id.hasPrefix("dec_") {
            // An answered or withdrawn decision is not on the board; read it so
            // the link still shows what happened instead of doing nothing.
            board.linkedID = nil
            Task {
                if let record: LAADecision = try? await bridge.read("/v1/decisions/\(id)"),
                   record.id == id { show(record) }
            }
        }
    }

    private func retry(_ item: LAADecision) async {
        retrying = item.id
        defer { retrying = nil }
        switch await board.retry(item, bridge: bridge) {
        case .done:
            retryFailure[item.id] = nil
            retried += 1
            remember(board.records[item.id] ?? Self.delivered(item))
        case .notDelivered(let reason), .failed(let reason):
            retryFailure[item.id] = reason
        case .gone:
            // The row already left the board; nothing is left to retry.
            retryFailure[item.id] = nil
        }
    }

    /// The same record with its delivery confirmed, so the 回答済み row does
    /// not keep the retry block after it went through.
    static func delivered(_ item: LAADecision) -> LAADecision {
        LAADecision(kind: item.kind, id: item.id, ref: item.ref, status: item.status, title: item.title,
                    summary: item.summary, options: item.options, allowOther: item.allowOther, impact: item.impact,
                    deadline: item.deadline, source: item.source, sourceRef: item.sourceRef, createdAt: item.createdAt,
                    answer: item.answer,
                    delivery: .init(state: "delivered", attempts: item.delivery?.attempts,
                                    deliveredAt: item.delivery?.deliveredAt, error: nil),
                    sessionId: item.sessionId)
    }

    // MARK: Text

    /// Source, deadline and the recommended choice on one quiet line; a close
    /// deadline is the only part that takes the attention colour.
    static func meta(_ item: LAADecision, now: Date = Date()) -> AttributedString? {
        var line = AttributedString()
        func add(_ text: String, color: Color = LAAColor.secondaryText, strong: Bool = false) {
            if !line.characters.isEmpty {
                var separator = AttributedString(" · ")
                separator.foregroundColor = LAAColor.secondaryText
                line += separator
            }
            var piece = AttributedString(text)
            piece.foregroundColor = color
            if strong { piece.inlinePresentationIntent = .stronglyEmphasized }
            line += piece
        }
        if let source = item.sourceLine { add(source) }
        if let deadline = LAADecisionDeadline.describe(item.deadline, now: now) {
            add(deadline.text, color: deadline.urgent ? LAAColor.attention : LAAColor.secondaryText, strong: deadline.urgent)
        }
        // An answer that did not arrive shows what was chosen, not the advice.
        if let answer = item.answer { add("回答 \(answer.label)") }
        else if let recommended = item.recommended { add("\(LAADecisionCopy.recommended) \(recommended.label)") }
        else if item.kind == .session, !item.summary.isEmpty { add(item.summary) }
        return line.characters.isEmpty ? nil : line
    }

    /// `S5 · 会話 · 返答済み 20:40`: the source, then when the answer went back.
    static func answeredLine(_ item: LAADecision, answer: LAADecision.Answer) -> AttributedString {
        var line = AttributedString()
        if let source = item.sourceLine {
            var piece = AttributedString(source)
            piece.foregroundColor = LAAColor.secondaryText
            line += piece
        }
        if item.deliveryWaiting {
            if !line.characters.isEmpty {
                var separator = AttributedString(" · ")
                separator.foregroundColor = LAAColor.secondaryText
                line += separator
            }
            var piece = AttributedString(LAADecisionCopy.waiting)
            piece.foregroundColor = LAAColor.secondaryText
            line += piece
        } else if let time = clock(answer.answeredAt) {
            if !line.characters.isEmpty {
                var separator = AttributedString(" · ")
                separator.foregroundColor = LAAColor.secondaryText
                line += separator
            }
            var piece = AttributedString(LAADecisionCopy.replied + " " + time)
            piece.foregroundColor = LAAColor.secondaryText
            line += piece
        }
        return line
    }

    /// `20:40` for a stamped answer, nil when the record carries no time.
    static func clock(_ stamp: String?) -> String? {
        guard let date = LAAWorkFreshness.date(stamp) else { return nil }
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// A row that wants the owner now: a deadline inside a day, or an answer
    /// that did not reach its conversation.
    static func needsAttention(_ item: LAADecision) -> Bool {
        if item.answer != nil { return item.deliveryFailed }
        return item.deliveryFailed || LAADecisionDeadline.describe(item.deadline)?.urgent == true
    }
}

/// One board row: title, one quiet line and an optional chevron on the phone.
/// No symbol tile; a plum rule and ▲ are all a row needs to say 要確認.
private struct LAADecisionRow: View {
    let item: LAADecision
    let meta: AttributedString
    let selected: Bool
    let desktop: Bool
    let open: () -> Void
    @State private var hovering = false

    private var attention: Bool { LAADecisionBoardView.needsAttention(item) }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: LAASpacing.x3) {
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                        if attention {
                            Text(verbatim: "▲")
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                                .accessibilityHidden(true)
                        }
                        if item.kind == .board { LAAWorkRefLabel(ref: item.ref) }
                        Text(verbatim: item.title)
                            .laaTextStyle(.body).fontWeight(.semibold)
                            .foregroundStyle(selected ? LAAColor.link : LAAColor.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if !meta.characters.isEmpty {
                        Text(meta).laaTextStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)

            }
            .padding(.horizontal, desktop ? LAASpacing.x3 : 0)
            .padding(.vertical, desktop ? LAASpacing.x3 : LAASpacing.x2)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .background(background, in: RoundedRectangle(cornerRadius: LAASpacing.x2))
            .overlay(alignment: .leading) {
                if attention { Rectangle().fill(LAAColor.attention).frame(width: 2) }
            }
            .clipShape(RoundedRectangle(cornerRadius: LAASpacing.x2))
        }
        .buttonStyle(LAADecisionPressStyle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: Color {
        if selected { return LAAColor.selectionFill }
        return hovering && desktop ? LAAColor.subtleSurface.opacity(0.7) : .clear
    }
}
#endif
