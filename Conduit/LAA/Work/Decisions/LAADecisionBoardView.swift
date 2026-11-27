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
    /// the list keeps its own record for the Answered section and the detail.
    @State private var answered: [LAADecision] = []
    /// For each row in `answered`, the board reads started when it got there.
    /// It leaves once a later read has come back without it, so a delivered
    /// answer does not stay on the board (2026-11-23). A record opened from a
    /// link stays while it is the one shown.
    @State private var answeredMark: [String: Int] = [:]
    @State private var linkedOnly = Set<String>()
    @State private var retrying: String?
    @State private var retryFailure: [String: String] = [:]
    @State private var retried = 0
    @FocusState private var listFocused: Bool
    /// A picture viewer is open over the detail: Esc is the viewer's.
    @State private var viewerOpen = false
    /// 回答済み is closed until the owner opens it, on the phone and the Mac.
    @State private var settledExpanded = LAADecisionSettled.expandedByDefault
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
            .onChange(of: knownIDs, initial: true) { _, _ in selectFirstIfNeeded() }
            .onChange(of: board.lastLoadStart) { _, start in pruneAnswered(after: start) }
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
            if openItems.isEmpty && inFlightItems.isEmpty && settledItems.isEmpty && !board.loading {
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

    /// Answers the Bridge still holds: a failed delivery with its retry, or
    /// one on its way. They stay in view under Open, never folded away.
    private var inFlightItems: [LAADecision] { board.items.filter { $0.answer != nil } }

    /// The one 回答済み area: the Bridge's settled answers of the last day,
    /// with this device's just-sent answers and linked records.
    private var settledItems: [LAADecision] {
        LAADecisionSettled.rows(board: board.settled, local: answered, linkedOnly: linkedOnly,
                                onBoard: Set(board.items.map(\.id)))
    }

    /// The rows the arrow keys walk: a closed 回答済み is skipped.
    private var rowIDs: [String] {
        (openItems + inFlightItems + (settledExpanded ? settledItems : [])).map(\.id)
    }

    /// Every row that can stay selected, folded or not.
    private var knownIDs: [String] { (openItems + inFlightItems + settledItems).map(\.id) }

    private var selectedItem: LAADecision? {
        guard let selectedID else { return nil }
        return board.items.first { $0.id == selectedID } ?? settledItems.first { $0.id == selectedID }
            ?? answered.first { $0.id == selectedID }
    }

    /// Ruled rows on the paper under English section labels, like Tasks and
    /// Sessions: no card per section (work-good, 2026-11-28).
    private var phoneList: some View {
        List {
            if case .failed(let text) = board.phase {
                Section {
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        Text(verbatim: text).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                        Button { Task { await board.load(bridge) } } label: { Text(verbatim: "Retry") }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: LAASpacing.horizontal, bottom: 0, trailing: LAASpacing.horizontal))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            if openItems.isEmpty && inFlightItems.isEmpty {
                Section {
                    Text(verbatim: LAADecisionCopy.empty)
                        .laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 0, leading: LAASpacing.horizontal, bottom: 0, trailing: LAASpacing.horizontal))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("work.decisions.empty")
                }
            }
            if !openItems.isEmpty || !inFlightItems.isEmpty {
                Section {
                    ForEach(openItems + inFlightItems) { item in phoneRow(item) }
                } header: {
                    phoneHeader(LAADecisionCopy.openSection, count: openItems.count)
                }
            }
            if !settledItems.isEmpty {
                Section {
                    if settledExpanded {
                        ForEach(settledItems) { item in phoneRow(item) }
                    }
                } header: {
                    settledHeader
                        .padding(.horizontal, LAASpacing.horizontal)
                        .listRowInsets(EdgeInsets())
                        .background(LAAColor.background)
                }
            }
        }
        .listStyle(.plain).textCase(nil)
        .environment(\.defaultMinListRowHeight, LAASpacing.minimumRowHeight)
        .scrollContentBackground(.hidden)
    }

    /// A flagged row gives its leading inset to the plum rule, so the rule sits
    /// in the margin and every title starts on the same line, at every text size.
    private func phoneRow(_ item: LAADecision) -> some View {
        let gutter = Self.needsAttention(item) ? LAADecisionRow.ruleGutter : 0
        return row(item)
            .listRowInsets(EdgeInsets(top: 0, leading: LAASpacing.horizontal - gutter, bottom: 0, trailing: LAASpacing.horizontal))
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(LAAColor.separator)
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in dimensions[.leading] + gutter }
    }

    /// `Open 4`, as Tasks writes its section headers: the name, then the count.
    private func phoneHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: LAASpacing.x2) {
            Text(verbatim: title).laaTextStyle(.section).foregroundStyle(LAAColor.text)
            Text(verbatim: "\(count)").laaTextStyle(.secondary).monospacedDigit()
                .foregroundStyle(LAAColor.secondaryText)
            Spacer(minLength: 0)
        }
        .frame(minHeight: LAASpacing.minimumTouchTarget)
        .padding(.horizontal, LAASpacing.horizontal)
        .listRowInsets(EdgeInsets())
        .background(LAAColor.background)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
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
                                Button { Task { await board.load(bridge) } } label: { Text(verbatim: "Retry") }
                            }
                            .padding(LAASpacing.x3)
                        }
                        if openItems.isEmpty && inFlightItems.isEmpty {
                            Text(verbatim: LAADecisionCopy.empty)
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                .padding(.horizontal, LAASpacing.x2 + LAASpacing.x3)
                                .padding(.vertical, LAASpacing.x3)
                                .accessibilityIdentifier("work.decisions.empty")
                        } else {
                            sectionTitle(LAADecisionCopy.openSection, count: openItems.isEmpty ? nil : openItems.count)
                            ForEach(openItems + inFlightItems) { item in
                                row(item, selected: selectedID == item.id)
                            }
                        }
                        if !settledItems.isEmpty {
                            settledHeader
                                .padding(.horizontal, LAASpacing.x2 + LAASpacing.x3)
                                .padding(.top, LAASpacing.x3)
                            if settledExpanded {
                                ForEach(settledItems) { item in
                                    row(item, selected: selectedID == item.id)
                                }
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
            // A Mac outline's keys: → opens 回答済み, ← closes it.
            .onKeyPress(.rightArrow) {
                guard !settledItems.isEmpty, !settledExpanded else { return .ignored }
                setSettled(true); return .handled
            }
            .onKeyPress(.leftArrow) {
                guard settledExpanded else { return .ignored }
                setSettled(false); return .handled
            }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.return) { if selectedID == nil { selectedID = rowIDs.first }; return .handled }
            .onKeyPress(.escape) { guard !viewerOpen else { return .ignored }; selectedID = nil; return .handled }
            .accessibilityIdentifier("work.decisions.list")
        } detail: {
            if let item = selectedItem {
                LAADecisionDetailView(item: item, board: board, drafts: drafts, onAnswered: remember) { _ in }
                    // A retry that went through is a new record: the screen
                    // starts over, so no stale failure line can stay.
                    .id(item.id + ":" + (item.delivery?.state ?? "-"))
                    .environment(\.laaDecisionViewerOpen, $viewerOpen)
            } else {
                Text(verbatim: "判断を選んでください")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("work.decisions.desktop")
    }

    /// `Open 2`. The Mac label starts where a row's title does.
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

    /// `回答済み 3` with a chevron that turns when open; the whole line toggles.
    private var settledHeader: some View {
        Button { setSettled(!settledExpanded) } label: {
            HStack(spacing: LAASpacing.x2) {
                // The phone's header as batch3 writes it (name in ink, count muted);
                // the Mac's as its other section label.
                Text(verbatim: LAADecisionSettled.title)
                    .laaTextStyle(.section).fontWeight(laaDesktop ? .semibold : .regular)
                    .foregroundStyle(laaDesktop ? LAAColor.secondaryText : LAAColor.text)
                Text(verbatim: "\(settledItems.count)")
                    .laaTextStyle(laaDesktop ? .section : .secondary).monospacedDigit()
                    .foregroundStyle(LAAColor.secondaryText)
                Spacer(minLength: LAASpacing.x2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LAAColor.secondaryText)
                    .rotationEffect(.degrees(settledExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: LAASpacing.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityLabel(Text(verbatim: "\(LAADecisionSettled.title)、\(settledItems.count)件"))
        .accessibilityValue(Text(verbatim: settledExpanded ? "Expanded" : "Collapsed"))
        .accessibilityHint(Text(verbatim: settledExpanded ? "Collapse" : "Expand"))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("work.decisions.settled")
    }

    private func setSettled(_ open: Bool) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { settledExpanded = open }
    }

    private func row(_ item: LAADecision, selected: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            LAADecisionRow(item: item, meta: metaLine(item), reason: settledReason(item), selected: selected,
                           desktop: laaDesktop, open: { show(item) })
                .contextMenu { rowMenu(item) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: LAADecisionCopy.accessibilityLabel(item)))
                .accessibilityAddTraits(.isButton)
                // An answered row is its own element: the open row's id goes
                // with the answer it no longer waits for.
                .accessibilityIdentifier(item.answer == nil ? "work.decision.\(item.id)"
                                                            : "work.decision.answered.\(item.id)")
            if item.deliveryFailed {
                undelivered(item)
                    // Under the title, not under the phone's rule gutter.
                    .padding(.leading, !laaDesktop && Self.needsAttention(item) ? LAADecisionRow.ruleGutter : 0)
            }
        }
        .padding(.horizontal, laaDesktop ? LAASpacing.x2 : 0)
    }

    @ViewBuilder private func rowMenu(_ item: LAADecision) -> some View {
        Button { show(item) } label: { Text(verbatim: "Open") }
        if item.deliveryFailed {
            Button { Task { await retry(item) } } label: { Text(verbatim: "Resend") }
        }
    }

    /// Source and deadline, or how the answer went back; no summary of what
    /// the screen already says.
    private func metaLine(_ item: LAADecision) -> AttributedString {
        if item.isSettled, let answer = item.answer { return Self.settledLine(item, answer: answer) }
        if let answer = item.answer { return Self.answeredLine(item, answer: answer) }
        return Self.meta(item) ?? AttributedString()
    }

    /// Monet's one-line reason under its settled answer.
    private func settledReason(_ item: LAADecision) -> String? {
        guard item.isSettled, item.answeredByMonet, let reason = item.answer?.reason?
            .trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return nil }
        return reason
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
                    if retrying == item.id { Text(verbatim: "Sending…") }
                    else {
                        Label { Text(verbatim: "Resend") } icon: { Image(systemName: "arrow.clockwise") }
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
                Button { Task { await board.load(bridge) } } label: { Text(verbatim: "Retry") }
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
            if !board.items.contains(where: { $0.id == item.id }) {
                if !board.settled.contains(where: { $0.id == item.id }) { store(item) }
                setSettled(true)
            }
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
        answeredMark[item.id] = board.loadsStarted
        linkedOnly.insert(item.id)
    }

    /// An answer that left for the conversation: the row moves to Answered
    /// until the next board read comes back.
    private func remember(_ item: LAADecision) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35)) {
            answered.removeAll { $0.id == item.id }
            answered.insert(item, at: 0)
            board.remove(item.id)
        }
        answeredMark[item.id] = board.loadsStarted
        linkedOnly.remove(item.id)
    }

    /// Drops the Answered rows a read that began after them no longer lists.
    private func pruneAnswered(after start: Int) {
        let keep = Self.keptAnswered(answered, marks: answeredMark, linkedOnly: linkedOnly, selectedID: selectedID,
                                     boardIDs: Set((board.items + board.settled).map(\.id)), lastLoadStart: start)
        guard keep.count != answered.count else { return }
        let kept = Set(keep.map(\.id))
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35)) { answered = keep }
        answeredMark = answeredMark.filter { kept.contains($0.key) }
        linkedOnly = linkedOnly.intersection(kept)
    }

    /// Pure rule for `pruneAnswered`, for unit tests.
    static func keptAnswered(_ answered: [LAADecision], marks: [String: Int], linkedOnly: Set<String>,
                             selectedID: String?, boardIDs: Set<String>, lastLoadStart: Int) -> [LAADecision] {
        answered.filter { item in
            if boardIDs.contains(item.id) { return true }
            if linkedOnly.contains(item.id), item.id == selectedID { return true }
            guard let mark = marks[item.id] else { return false }
            return lastLoadStart <= mark
        }
    }

    /// A selection inside a closed 回答済み stays; a vanished one moves to the
    /// first row the keys can reach.
    private func selectFirstIfNeeded() {
        guard laaDesktop else { return }
        if let selectedID, knownIDs.contains(selectedID) { return }
        selectedID = rowIDs.first
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

    /// The same record with its delivery confirmed, so the Answered row does
    /// not keep the retry block after it went through.
    static func delivered(_ item: LAADecision) -> LAADecision {
        LAADecision(kind: item.kind, id: item.id, ref: item.ref, status: item.status, title: item.title,
                    summary: item.summary, options: item.options, allowOther: item.allowOther, impact: item.impact,
                    deadline: item.deadline, source: item.source, sourceRef: item.sourceRef, createdAt: item.createdAt,
                    answer: item.answer,
                    delivery: .init(state: "delivered", attempts: item.delivery?.attempts,
                                    deliveredAt: item.delivery?.deliveredAt, error: nil),
                    sessionId: item.sessionId, category: item.category, images: item.images,
                    overturned: item.overturned, monetAnswer: item.monetAnswer)
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
        if item.isMonetQueue { add("Monet担当") }
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
        if answer.answeredBy == "monet" {
            if !line.characters.isEmpty { line += AttributedString(" · ") }
            var piece = AttributedString(LAADecisionSettled.monetMark)
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

    /// A settled row's line: `Monetの回答 · <label>`, `社長が変更 · <label>`, or
    /// the owner's label alone. The mark is quiet; the choice is in the ink.
    static func settledLine(_ item: LAADecision, answer: LAADecision.Answer) -> AttributedString {
        var line = AttributedString()
        if let mark = LAADecisionSettled.mark(item) {
            var piece = AttributedString(mark + " · ")
            piece.foregroundColor = LAAColor.secondaryText
            line += piece
        }
        var label = AttributedString(answer.label)
        label.foregroundColor = LAAColor.text
        line += label
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
        if item.answer != nil { return item.deliveryFailed && !item.canOverturn }
        if item.isMonetQueue { return false }
        return item.deliveryFailed || LAADecisionDeadline.describe(item.deadline)?.urgent == true
    }
}

/// One board row: title, one quiet line and an optional chevron on the phone.
/// No symbol tile; a plum rule and ▲ are all a row needs to say 要確認.
private struct LAADecisionRow: View {
    let item: LAADecision
    let meta: AttributedString
    /// Monet's reason under a settled answer.
    var reason: String? = nil
    let selected: Bool
    let desktop: Bool
    let open: () -> Void
    @State private var hovering = false

    private var attention: Bool { LAADecisionBoardView.needsAttention(item) }

    /// The plum rule's width and the gap after it. On the phone the row's
    /// list inset gives this much back, so titles stay aligned with the rows
    /// that carry no rule.
    static let ruleWidth: CGFloat = 2
    static let ruleGutter: CGFloat = ruleWidth + LAASpacing.x2

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 0) {
                // A column of its own, never laid over the text: the earlier
                // overlay drew over the subtitle's first glyphs and under the ▲.
                if attention && !desktop {
                    rule.padding(.trailing, LAASpacing.x2)
                }
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                        if attention {
                            Text(verbatim: "▲")
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                                .accessibilityHidden(true)
                        }
                        if item.kind == .board { LAAWorkRefLabel(ref: item.ref) }
                        Text(verbatim: item.title)
                            // A settled answer recedes: the title in the regular weight.
                            .laaTextStyle(.body).fontWeight(item.isSettled ? .regular : .semibold)
                            .foregroundStyle(selected ? LAAColor.link : LAAColor.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if !item.images.isEmpty {
                            Image(systemName: "photo")
                                .laaTextStyle(.secondary)
                                .foregroundStyle(LAAColor.secondaryText)
                                .accessibilityHidden(true)
                                .accessibilityIdentifier("work.decision.row.photo")
                        }
                    }
                    if !meta.characters.isEmpty {
                        Text(meta).laaTextStyle(.secondary).lineLimit(1)
                    }
                    if let reason {
                        Text(verbatim: reason).laaTextStyle(.secondary)
                            .foregroundStyle(LAAColor.secondaryText).lineLimit(1)
                    }
                }
                .padding(.vertical, desktop ? LAASpacing.x3 : LAASpacing.x2)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, desktop ? LAASpacing.x3 : 0)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .background(background, in: RoundedRectangle(cornerRadius: LAASpacing.x2))
            // On the Mac the rule sits in the row's own padding (x3), clear of the text.
            .overlay(alignment: .leading) {
                if attention && desktop { rule }
            }
            .clipShape(RoundedRectangle(cornerRadius: LAASpacing.x2))
        }
        .buttonStyle(LAADecisionPressStyle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var rule: some View {
        Rectangle().fill(LAAColor.attention).frame(width: Self.ruleWidth)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var background: Color {
        if selected { return LAAColor.selectionFill }
        return hovering && desktop ? LAAColor.subtleSurface.opacity(0.7) : .clear
    }
}
#endif
