#if LAA_BUILD
import SwiftUI

/// The Work hub's board: one row per thing waiting for the owner. The title
/// says what to decide; one quiet line adds source, deadline and the
/// recommended choice.
struct LAADecisionBoardView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var board: LAADecisionBoard
    @ObservedObject var drafts: ComposerDraftStore
    @State private var selected: LAADecision?
    @State private var retrying: String?
    @State private var retryFailure: [String: String] = [:]
    @State private var retried = 0
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
            .sheet(item: $selected) { item in
                NavigationStack {
                    LAADecisionDetailView(item: item, board: board, drafts: drafts) { removed in
                        selected = nil
                        guard removed else { return }
                        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4)) { board.remove(item.id) }
                        Task { await board.load(bridge) }
                    }
                }
            }
            .sensoryFeedback(.success, trigger: retried)
            .accessibilityIdentifier("work.decisions")
    }

    @ViewBuilder private var content: some View {
        switch board.phase {
        case .unsupported:
            message(icon: "desktopcomputer", title: LAADecisionCopy.unsupported, detail: LAADecisionCopy.unsupportedDetail,
                    identifier: "work.decisions.unsupported")
        case .failed(let text) where board.items.isEmpty:
            message(icon: "wifi.exclamationmark", title: "判断ボードを読めません", detail: text,
                    identifier: "work.decisions.failure", retry: true)
        case .idle where board.loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where board.items.isEmpty:
            message(icon: "checkmark.circle", title: LAADecisionCopy.empty, detail: LAADecisionCopy.emptyDetail,
                    identifier: "work.decisions.empty")
        default:
            list
        }
    }

    private var list: some View {
        List {
            if case .failed(let text) = board.phase {
                Section {
                    Text(verbatim: text).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    Button { Task { await board.load(bridge) } } label: { Text(verbatim: "読み直す") }
                }
            }
            Section {
                ForEach(board.items) { item in
                    row(item)
                        .listRowBackground(LAAColor.surface)
                        .transition(.opacity)
                }
            } footer: {
                Text(verbatim: "選ぶと、依頼元の会話へ届きます。")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func row(_ item: LAADecision) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Button { selected = item } label: {
                HStack(alignment: .center, spacing: LAASpacing.x3) {
                    badge(item)
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                            if item.kind == .board { LAAWorkRefLabel(ref: item.ref) }
                            Text(verbatim: item.title)
                                .laaTextStyle(.body).fontWeight(.semibold)
                                .foregroundStyle(LAAColor.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        if let meta = Self.meta(item) {
                            Text(meta).laaTextStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LAAColor.separator)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(LAADecisionPressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: LAADecisionCopy.accessibilityLabel(item)))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("work.decision.\(item.id)")
            if item.deliveryFailed { undelivered(item) }
        }
    }

    private func badge(_ item: LAADecision) -> some View {
        let icon = item.deliveryFailed ? "arrow.clockwise" : item.kind == .session ? "bubble.left.and.text.bubble.right" : "questionmark"
        return Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(item.deliveryFailed ? LAAColor.attention : LAAColor.link)
            .frame(width: 36, height: 36)
            .background(LAAColor.selectionFill, in: Circle())
            .accessibilityHidden(true)
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
                    if retrying == item.id { ProgressView() }
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
        .padding(.leading, 36 + LAASpacing.x3)
        .padding(.bottom, LAASpacing.x1)
    }

    private func message(icon: String, title: String, detail: String, identifier: String, retry: Bool = false) -> some View {
        ContentUnavailableView {
            Label { Text(verbatim: title) } icon: { Image(systemName: icon).foregroundStyle(LAAColor.link) }
        } description: {
            Text(verbatim: detail)
        } actions: {
            if retry {
                Button { Task { await board.load(bridge) } } label: { Text(verbatim: "読み直す") }
                    .laaGlassButton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }

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

    private func openLinked() {
        #if DEBUG
        guard loadsOnAppear else { return }
        #endif
        guard let id = board.linkedID, board.phase != .idle else { return }
        if let item = board.items.first(where: { $0.id == id }) {
            board.linkedID = nil
            selected = item
        } else if board.phase == .loaded, id.hasPrefix("dec_") {
            // An answered or withdrawn decision is not on the board; read it so
            // the link still shows what happened instead of doing nothing.
            board.linkedID = nil
            Task {
                if let record: LAADecision = try? await bridge.read("/v1/decisions/\(id)"),
                   record.status == "open" || record.deliveryFailed { selected = record }
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
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4)) { board.remove(item.id) }
        case .notDelivered(let reason), .failed(let reason):
            retryFailure[item.id] = reason
        }
    }
}
/// The Work hub pill's label: the section name and, when something waits,
/// its count.
struct LAADecisionPillTitle: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: LAASpacing.x1) {
            Text(verbatim: title)
            if count > 0 {
                Text(verbatim: "\(count)").monospacedDigit()
                    .accessibilityLabel(Text(verbatim: "\(count)件"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
