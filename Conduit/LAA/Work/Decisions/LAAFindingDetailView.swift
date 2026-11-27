#if LAA_BUILD
import SwiftUI

/// One finding, in the contract's order: 何に気づいたか, 根拠, 対応方法,
/// 影響と手間, 見つけた会話. Pictures and links use the D-17 parts. The only
/// actions are 「Monetに任せる」 and the quiet 「見送る」, and only while open.
struct LAAFindingDetailView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.laaDesktop) private var laaDesktop
    @ObservedObject var board: LAAFindingBoard
    let onFinished: () -> Void

    @State private var item: LAAFinding
    @State private var viewer: LAADecisionImageViewer.Request?
    @State private var browser: LAADecisionBrowserPage?
    @Environment(\.laaDecisionViewerOpen) private var viewerOpen

    init(item: LAAFinding, board: LAAFindingBoard, onFinished: @escaping () -> Void) {
        _item = State(initialValue: item)
        self.board = board
        self.onFinished = onFinished
    }

    private var sending: Bool { board.sendingIDs.contains(item.id) }

    var body: some View {
        Group {
            if laaDesktop {
                scrollBody.laaReadableWidth(LAADesktopMetrics.documentWidth)
            } else {
                scrollBody.safeAreaInset(edge: .bottom) { if item.isOpen { actionBar } }
            }
        }
        .background { if !laaDesktop { LAAColor.background.ignoresSafeArea() } }
        .foregroundStyle(LAAColor.text)
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !laaDesktop {
                ToolbarItem(placement: .cancellationAction) {
                    LAACloseButton { onFinished() }
                        .accessibilityIdentifier("work.finding.close")
                }
            }
        }
        .onChange(of: board.items) { _, items in
            if let record = items.first(where: { $0.id == item.id }), record != item { item = record }
        }
        .fullScreenCover(item: $viewer) { request in
            LAADecisionImageViewer(request: request).environmentObject(bridge)
        }
        .laaDecisionLinks($browser)
        .onChange(of: viewer != nil) { _, open in viewerOpen?.wrappedValue = open }
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                header
                section(LAAFindingCopy.sectionFound, text: item.found, identifier: "work.finding.found") {
                    if !item.images.isEmpty {
                        LAADecisionImageStrip(item: item.imageCarrier) { viewer = .init(item: item.imageCarrier, start: $0) }
                            .padding(.vertical, LAASpacing.x1)
                    }
                }
                section(LAAFindingCopy.sectionEvidence, text: item.evidence, identifier: "work.finding.evidence")
                section(LAAFindingCopy.sectionPlan, text: item.plan, identifier: "work.finding.plan")
                section(LAAFindingCopy.sectionEffort, text: LAAFindingCopy.effortLine(item.effort) ?? "",
                        identifier: "work.finding.effort")
                section(LAAFindingCopy.sectionSource, text: item.sourceLine ?? LAAFindingCopy.unknownSource,
                        identifier: "work.finding.source")
                if laaDesktop, item.isOpen { desktopAction }
            }
            .padding(.horizontal, laaDesktop ? LAASpacing.x8 : LAASpacing.horizontal)
            .padding(.top, laaDesktop ? LAASpacing.x6 : LAASpacing.x2)
            .padding(.bottom, LAASpacing.x8)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            if let status = statusLine {
                Text(verbatim: status).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("work.finding.status")
            }
            if let ref = LAAWorkRef.display(item.ref) {
                Text(verbatim: ref).laaTextStyle(.secondary).monospacedDigit().foregroundStyle(LAAColor.secondaryText)
            }
            Text(verbatim: item.title)
                .laaTextStyle(.heading).fontWeight(.semibold)
                .foregroundStyle(LAAColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("work.finding.title")
        }
    }

    /// Monet's turn or the result; nothing while it is the owner's to choose.
    private var statusLine: String? {
        item.status == .open ? nil : LAAFindingCopy.meta(item)
    }

    private func section(_ title: String, text: String, identifier: String) -> some View {
        section(title, text: text, identifier: identifier) { EmptyView() }
    }

    @ViewBuilder
    private func section<Extra: View>(_ title: String, text: String, identifier: String,
                                      @ViewBuilder extra: () -> Extra) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                Text(verbatim: title).laaTextStyle(.section).fontWeight(.semibold)
                    .foregroundStyle(LAAColor.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                Text(LAADecisionLinks.attributed(trimmed)).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                extra()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
        }
    }

    // MARK: Actions

    @ViewBuilder private var failureText: some View {
        if let failure = board.failure {
            Text(verbatim: failure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("work.finding.failure")
        }
    }

    private var actionBar: some View {
        VStack(spacing: LAASpacing.x2) {
            failureText
            delegateButton(fullWidth: true)
            dismissButton
        }
        .padding(.horizontal, LAASpacing.horizontal)
        .padding(.vertical, LAASpacing.x2)
    }

    private var desktopAction: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            failureText
            HStack(spacing: LAASpacing.x4) {
                Spacer(minLength: 0)
                dismissButton
                delegateButton(fullWidth: false)
            }
        }
    }

    private func delegateButton(fullWidth: Bool) -> some View {
        Button { Task { await delegate() } } label: {
            Text(verbatim: sending ? "送信中" : LAAFindingCopy.delegate).fontWeight(.semibold)
                .foregroundStyle(LAAColor.filledButtonText)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .laaGlassButton(prominent: true)
        .disabled(sending)
        .accessibilityIdentifier("work.finding.delegate")
    }

    private var dismissButton: some View {
        Button { Task { await dismiss() } } label: {
            Text(verbatim: LAAFindingCopy.dismiss)
                .laaTextStyle(.body)
                .underline()
                .foregroundStyle(LAAColor.secondaryText)
                .frame(minHeight: LAASpacing.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(LAADecisionPressStyle())
        .disabled(sending)
        .accessibilityIdentifier("work.finding.dismiss")
    }

    private func delegate() async {
        if await board.delegate(item, bridge: bridge) {
            if let record = board.items.first(where: { $0.id == item.id }) { item = record }
            if !laaDesktop { onFinished() }
        }
    }

    /// The row leaves at once; on the phone the sheet closes with it. A
    /// refusal brings the row back and says why above the list.
    private func dismiss() async {
        let target = item
        if !laaDesktop { onFinished() }
        await board.dismiss(target, bridge: bridge)
    }
}
#endif
