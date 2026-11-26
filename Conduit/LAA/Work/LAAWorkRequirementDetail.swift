#if LAA_BUILD
import SwiftUI

/// One requirement's own page, opened from its line in the project: the full
/// title, its state (changed from the mark), the note, who added it, when it
/// last changed and the sessions working on it. The list shows none of this
/// (owner, 2026-11-26: the opened project was too dense).
struct LAAWorkRequirementDetail<SessionView: View>: View {
    /// The current reading of the requirement; nil once it is withdrawn or
    /// gone from the project, and the page goes back.
    let requirement: LAAWorkRequirement?
    let linked: [LAAWorkLinkedSession]
    var busy = false
    var canChange = true
    let setStatus: (LAAWorkRequirementStatus) -> Void
    let withdraw: (LAAWorkRequirement) -> Void
    @ViewBuilder let session: (String) -> SessionView

    @Environment(\.dismiss) private var dismiss
    @Environment(\.laaDesktop) private var laaDesktop
    @State private var openedSession: String?
    @State private var confirmingWithdraw = false

    var body: some View {
        ZStack {
            LAAColor.background.ignoresSafeArea()
            ScrollView {
                if let requirement { page(requirement) }
            }
        }
        .navigationTitle(Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .tint(LAAColor.link)
        .accessibilityIdentifier("laa.work.requirement.detail")
        .navigationDestination(item: $openedSession) { id in session(id) }
        .onChange(of: requirement == nil) { _, gone in if gone { dismiss() } }
        .confirmationDialog(Text(verbatim: requirement.map { LAACopy.WorkProject.withdrawTitle($0.title) } ?? ""),
                            isPresented: $confirmingWithdraw, titleVisibility: .visible) {
            Button(role: .destructive) {
                if let requirement { withdraw(requirement) }
            } label: { Text(verbatim: LAACopy.WorkProject.withdraw) }
            Button(role: .cancel) {} label: { Text(verbatim: LAACopy.WorkTab.cancel) }
        } message: {
            Text(verbatim: LAACopy.WorkProject.withdrawMessage)
        }
    }

    private func page(_ requirement: LAAWorkRequirement) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x6) {
            VStack(alignment: .leading, spacing: LAASpacing.x3) {
                Text(verbatim: requirement.title)
                    .font(LAAType.title(requirement.title))
                    .foregroundStyle(LAAColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("laa.work.requirement.title")
                HStack(spacing: LAASpacing.x2) {
                    LAAWorkRequirementStatusControl(requirement: requirement, busy: busy, canChange: canChange,
                                                    setStatus: setStatus, withdraw: { confirmingWithdraw = true })
                    Text(verbatim: requirement.status.label).laaTextStyle(.secondary).fontWeight(.semibold)
                        .foregroundStyle(requirement.status == .awaitingDecision ? LAAColor.attention : LAAColor.text)
                        .padding(.leading, -LAASpacing.x2)
                    Text(verbatim: requirement.addedByAI ? LAACopy.WorkProject.addedByAI : LAACopy.WorkProject.ownerHint)
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    Spacer(minLength: 0)
                    if let updated = Self.updated(requirement.updatedAt) {
                        Text(verbatim: updated).laaTextStyle(.secondary).monospacedDigit()
                            .foregroundStyle(LAAColor.secondaryText)
                    }
                }
                .opacity(busy ? 0.5 : 1)
                .accessibilityIdentifier("laa.work.requirement.status")
            }
            if let details = requirement.details {
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    heading(LAACopy.WorkProject.details)
                    Text(verbatim: details).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("laa.work.requirement.details")
                }
            }
            if !linked.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    heading(LAACopy.WorkProject.linkedSessions)
                    ForEach(linked) { linkedSession in sessionRow(linkedSession) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("laa.work.requirement.sessions")
            }
            if canChange {
                Button(role: .destructive) { confirmingWithdraw = true } label: {
                    Label { Text(verbatim: LAACopy.WorkProject.withdraw) } icon: { Image(systemName: "minus.circle") }
                        .laaTextStyle(.secondary)
                        .frame(minHeight: LAASpacing.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LAAColor.attention)
                .accessibilityIdentifier("laa.work.requirement.withdraw")
            }
        }
        .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4)
        .frame(maxWidth: laaDesktop ? LAADesktopMetrics.documentWidth : 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: laaDesktop ? .center : .leading)
    }

    private func heading(_ text: String) -> some View {
        Text(verbatim: text).laaTextStyle(.section).foregroundStyle(LAAColor.text)
            .accessibilityAddTraits(.isHeader)
    }

    private func sessionRow(_ linked: LAAWorkLinkedSession) -> some View {
        Button { openedSession = linked.id } label: {
            HStack(spacing: LAASpacing.x2) {
                LAAWorkStatusMark(status: linked.mark)
                if let ref = LAAWorkRef.display(linked.ref) {
                    Text(verbatim: ref).laaTextStyle(.secondary).monospacedDigit().foregroundStyle(LAAColor.secondaryText)
                }
                Text(verbatim: linked.name).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(minHeight: LAASpacing.minimumTouchTarget)
            .overlay(alignment: .bottom) { Rectangle().fill(LAAColor.separator).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(linked.name)、\(linked.statusLabel)"))
        .accessibilityIdentifier("laa.work.requirement.session.\(linked.id)")
    }

    /// `Updated 11/26 10:28`, from the Bridge's ISO time.
    static func updated(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return LAACopy.WorkProject.updated(formatter.string(from: date))
    }
}
#endif
