#if LAA_BUILD
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Progress meter

/// The share of a project's requirements that are done, on the app's one
/// meter: the Usage bar's track, height and teal, so every bar in the app
/// reads the same. It counts up and has no warning colour: a finished
/// project is not a full disk.
struct LAAWorkProjectMeter: View {
    let fraction: Double
    var body: some View {
        LAAUsageMeterTrack(fraction: fraction, level: .normal)
    }
}

// MARK: - List row

/// One project in Work › Projects, on the phone and the Mac: its name, how
/// many requirements are done, Monet's note in a line, and a mark while any
/// of its sessions runs or waits for the owner.
struct LAAWorkProjectRow: View {
    let project: LAAWorkProject
    var activity: LAAWorkProjectActivity = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                LAAWorkRefLabel(ref: project.ref)
                Text(verbatim: project.name).laaTextStyle(.body).fontWeight(.semibold)
                    .foregroundStyle(LAAColor.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: LAASpacing.x2)
                activityMark
            }
            progressLine
            if let note = project.progressNote {
                Text(verbatim: note).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(1)
            }
        }
        .padding(.horizontal, LAASpacing.x4)
        .padding(.vertical, LAASpacing.x3)
        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    @ViewBuilder private var activityMark: some View {
        switch activity {
        case .idle: EmptyView()
        case .running(let count), .decision(let count):
            HStack(spacing: 4) {
                LAAWorkStatusMark(status: activity == .running(count) ? .running : .decision)
                // The word goes with the number, so it never reads as the
                // requirements' 9 / 13 beside it (BUS-508).
                Text(verbatim: "\(LAACopy.WorkProject.sessionStatus(activity == .running(count) ? .running : .decision)) \(count)")
                    .laaTextStyle(.secondary).monospacedDigit().fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(activity == .running(count) ? LAAColor.secondaryText : LAAColor.attention)
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            .accessibilityIdentifier("laa.work.project.activity.\(project.id)")
        }
    }

    @ViewBuilder private var progressLine: some View {
        let time = LAAWorkSessionStyle.relative(project.updatedAt ?? "")
        if let progress = project.progress, progress.total > 0 {
            HStack(spacing: LAASpacing.x3) {
                LAAWorkProjectMeter(fraction: progress.fraction).frame(maxWidth: 160)
                Text(verbatim: "\(progress.completed) / \(progress.total)")
                    .laaTextStyle(.secondary).monospacedDigit().foregroundStyle(LAAColor.text)
                    .fixedSize()
                if let time {
                    Text(verbatim: time).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("laa.work.project.progress.\(project.id)")
        } else {
            Text(verbatim: ["—", LAACopy.WorkProject.noRequirementsShort, time].compactMap { $0 }.joined(separator: " · "))
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(1)
        }
    }

    private var accessibilityText: String {
        var parts = [(project.ref.map { "\($0) " } ?? "") + project.name]
        if let progress = project.progress, progress.total > 0 {
            parts.append(LAACopy.WorkProject.progressLabel(progress.completed, of: progress.total))
        } else {
            parts.append(LAACopy.WorkProject.noRequirementsShort)
        }
        if let activity = LAACopy.WorkProject.activity(activity) { parts.append(activity) }
        if let note = project.progressNote { parts.append(note) }
        return parts.joined(separator: "、")
    }
}

// MARK: - Detail page

/// What the detail knows when it draws. The project itself always comes from
/// the list, so the name never waits for the detail.
enum LAAWorkProjectPhase: Equatable {
    /// No detail read has finished yet, and nothing is kept on the device.
    case loading
    case ready
    /// The read failed; the rows shown (if any) are the last ones kept.
    case failed(String)
    /// The Mac was out of reach; the rows are the ones kept at that time.
    case offline(Date?)
}

/// Everything the detail page can ask its owner view to do. Fixtures pass
/// closures that change nothing.
struct LAAWorkProjectActions {
    var openSession: (String) -> Void = { _ in }
    var setStatus: (LAAWorkRequirement, LAAWorkRequirementStatus) -> Void = { _, _ in }
    var withdraw: (LAAWorkRequirement) -> Void = { _ in }
    /// Opens one requirement's own page (full text, notes and sessions).
    var openRequirement: (String) -> Void = { _ in }
    var addRequirement: () -> Void = {}
    var startSession: () -> Void = {}
    var editInstructions: () -> Void = {}
    var addFile: () -> Void = {}
    var removeFile: (LAAWorkProjectFile) -> Void = { _ in }
    var retry: () -> Void = {}
    var toggleArchived: () -> Void = {}
    /// Reads the next page of the active (false) or archived (true) sessions.
    var readMore: (Bool) -> Void = { _ in }
}

/// One project, opened: the heading with how far it has come, Monet's note,
/// the requirements by state, then its sessions, instructions and files.
/// The requirements are the page's subject; the owner's controls stay small
/// because Monet keeps them current.
struct LAAWorkProjectPage: View {
    @Environment(\.laaDesktop) private var laaDesktop
    let project: LAAWorkProject
    /// Requirements, note and compact sessions from the detail (or the copy
    /// kept on the device). Nil before the first read.
    let detail: LAAWorkProjectSnapshot?
    let sessions: [LAAWorkSession]
    var archivedSessions: [LAAWorkSession]? = nil
    var options: LAAWorkSessionOptions? = nil
    let phase: LAAWorkProjectPhase
    var actionError: String? = nil
    /// The requirement whose change is being sent.
    var busyRequirement: String? = nil
    var uploading = false
    var showArchived = false
    /// The Bridge holds more rows past the ones shown.
    var moreSessions = false
    var moreArchived = false
    var readingMore = false
    var canChange = true
    var actions = LAAWorkProjectActions()

    /// Groups the owner opened or closed; the rest follow `openByDefault`.
    @State private var groupOpen: [LAAWorkRequirementStatus: Bool] = [:]
    @State private var withdrawing: LAAWorkRequirement?

    private var board: LAAWorkRequirementBoard? { detail?.requirements.map(LAAWorkRequirementBoard.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x8) {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                heading
                banners
                if let board {
                    if board.summary.rate != nil { LAAWorkProjectSummary(board: board) }
                    else { Text(verbatim: "—").laaTextStyle(.secondary).accessibilityLabel(LAACopy.WorkProject.noRequirementsShort) }
                }
                if let note = detail?.progressNote { LAAWorkProjectNote(text: note) }
            }
            requirementsSection
            sessionsSection
            instructionsSection
            filesSection
        }
        .laaTextStyle(.body)
        .foregroundStyle(LAAColor.text)
        .confirmationDialog(Text(verbatim: withdrawing.map { LAACopy.WorkProject.withdrawTitle($0.title) } ?? ""),
                            isPresented: Binding(get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } }),
                            titleVisibility: .visible, presenting: withdrawing) { requirement in
            Button(role: .destructive) { actions.withdraw(requirement); withdrawing = nil } label: {
                Text(verbatim: LAACopy.WorkProject.withdraw)
            }
            Button(role: .cancel) { withdrawing = nil } label: { Text(verbatim: LAACopy.WorkTab.cancel) }
        } message: { _ in
            Text(verbatim: LAACopy.WorkProject.withdrawMessage)
        }
    }

    // MARK: Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            LAAWorkRefLabel(ref: project.ref)
            Text(verbatim: project.name)
                .font(LAAType.title(project.name))
                .foregroundStyle(LAAColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("laa.work.project.title")
        }
    }

    @ViewBuilder private var banners: some View {
        switch phase {
        case .failed(let text): LAAWorkProjectNotice(text: text, attention: true, retry: actions.retry)
                .accessibilityIdentifier("laa.work.project.failure")
        case .offline(let date): LAAWorkProjectNotice(text: LAACopy.WorkProject.offline(since: date), attention: true,
                                                      retry: actions.retry)
                .accessibilityIdentifier("laa.work.project.offline")
        case .loading, .ready: EmptyView()
        }
        if let actionError {
            LAAWorkProjectNotice(text: actionError, attention: true)
                .accessibilityIdentifier("laa.work.project.actionError")
        }
    }

    // MARK: Requirements

    private var requirementsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading(LAACopy.WorkProject.requirements, count: board?.summary.total,
                           action: detail?.requirements != nil && canChange
                               ? (LAACopy.WorkProject.add, "plus", "laa.work.project.addRequirement", actions.addRequirement)
                               : nil)
            requirementsContent
            if let log = detail?.requirementDenominatorLog, !log.isEmpty {
                DisclosureGroup {
                    ForEach(Array(log.reversed().enumerated()), id: \.offset) { _, change in
                        let date = LAAWorkFreshness.date(change.at).map { LAADateText.string($0, .monthDay) } ?? ""
                        Text(verbatim: "\(date) \(change.delta > 0 ? "+" : "")\(change.delta) · \(change.reason)")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                } label: {
                    Text(verbatim: "要件数の変更").laaTextStyle(.secondary)
                }
                .padding(.vertical, LAASpacing.x2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laa.work.project.requirements")
    }

    @ViewBuilder private var requirementsContent: some View {
        if let board {
            if board.groups.isEmpty {
                Text(verbatim: LAACopy.WorkProject.noRequirements)
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .padding(.vertical, LAASpacing.x3)
                    .accessibilityIdentifier("laa.work.project.requirements.empty")
            } else {
                ForEach(board.groups) { group in groupView(group, opensByDefault: board.openByDefault.contains(group.status)) }
            }
        } else if phase == .loading {
            LAALoadingDots()
        } else if phase == .ready {
            LAAWorkProjectNotice(text: LAACopy.WorkProject.bridgeTooOld, attention: false)
                .padding(.vertical, LAASpacing.x3)
                .accessibilityIdentifier("laa.work.project.requirements.unsupported")
        } else {
            // Failed or offline before the first read: say so instead of an empty heading.
            Text(verbatim: LAACopy.WorkProject.requirementsUnread)
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                .padding(.vertical, LAASpacing.x3)
                .accessibilityIdentifier("laa.work.project.requirements.unread")
        }
    }

    /// One status: a heading that opens and closes it (a chevron, no words)
    /// and, when open, one line per requirement.
    @ViewBuilder private func groupView(_ group: LAAWorkRequirementBoard.Group, opensByDefault: Bool) -> some View {
        let open = groupOpen[group.status] ?? opensByDefault
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { groupOpen[group.status] = !open } } label: {
                groupHeading(group, open: open)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(group.status.label) \(group.items.count)"))
            .accessibilityValue(Text(verbatim: open ? LAACopy.WorkProject.expandedValue : LAACopy.WorkProject.collapsedValue))
            .accessibilityHint(Text(verbatim: open ? LAACopy.WorkProject.collapseHint : LAACopy.WorkProject.expandHint))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("laa.work.project.group.\(group.status.rawValue).toggle")
            if open {
                ForEach(group.items) { requirement in
                    LAAWorkRequirementRow(requirement: requirement,
                                          busy: busyRequirement == requirement.id, canChange: canChange,
                                          setStatus: { actions.setStatus(requirement, $0) },
                                          withdraw: { withdrawing = requirement },
                                          open: { actions.openRequirement(requirement.id) })
                    if requirement.id != group.items.last?.id {
                        Rectangle().fill(LAAColor.separator).frame(height: 1).padding(.leading, 32).accessibilityHidden(true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laa.work.project.group.\(group.status.rawValue)")
    }

    private func groupHeading(_ group: LAAWorkRequirementBoard.Group, open: Bool) -> some View {
        HStack(spacing: LAASpacing.x2) {
            LAAWorkStatusMark(status: group.status.mark)
            Text(verbatim: group.status.label).laaTextStyle(.secondary).fontWeight(.semibold)
                .foregroundStyle(group.status == .awaitingDecision ? LAAColor.attention : LAAColor.text)
            Text(verbatim: "\(group.items.count)").laaTextStyle(.secondary).monospacedDigit()
                .foregroundStyle(LAAColor.secondaryText)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LAAColor.secondaryText)
                .rotationEffect(.degrees(open ? 0 : -90))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(LAAColor.separator).frame(height: 1) }
        .contentShape(Rectangle())
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            // No bare total beside the heading: 「Sessions 7」 read as seven at
            // work when they were waiting (BUS-508). The line says which.
            sectionHeading(LAACopy.WorkTab.sessions, count: nil,
                           action: canChange ? (LAACopy.WorkProject.startSession, "plus", "work.project.newSession", actions.startSession) : nil)
            if detail != nil || !sessions.isEmpty {
                LAAWorkSessionTallyLine(tally: sessionTally, identifier: "laa.work.project.sessions.tally")
            }
            // While the first read runs, "none yet" would be a claim the app can't make.
            if !(sessions.isEmpty && phase == .loading) {
                sessionRows(sessions, empty: LAACopy.WorkProject.noSessions)
            }
            if moreSessions { readMoreButton(archived: false) }
            if showArchived, let archivedSessions {
                Text(verbatim: LAACopy.WorkTab.archived).laaTextStyle(.secondary).fontWeight(.semibold)
                    .foregroundStyle(LAAColor.secondaryText).padding(.top, LAASpacing.x2)
                sessionRows(archivedSessions, empty: LAACopy.WorkProject.noArchived)
                if moreArchived { readMoreButton(archived: true) }
            }
            if archivedCount != 0 {
                Button(action: actions.toggleArchived) {
                    Label { Text(verbatim: showArchived ? LAACopy.WorkProject.hideArchived : archivedTitle) }
                        icon: { Image(systemName: showArchived ? "arrow.uturn.left" : "archivebox") }
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                        .frame(minHeight: LAASpacing.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("laa.work.project.archivedToggle")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laa.work.project.sessions")
    }

    /// Running, awaiting the owner and waiting: the Bridge's totals before
    /// paging, else the compact rows, else the full rows shown.
    private var sessionTally: LAAWorkSessionTally {
        if detail?.sessionCounts?.running != nil || detail?.sessions != nil {
            return LAAWorkSessionTally(counts: detail?.sessionCounts, compact: detail?.sessions)
        }
        return LAAWorkSessionTally(sessions: sessions)
    }
    /// Archived sessions the detail counted; nil when it could not say.
    private var archivedCount: Int? {
        detail?.sessionCounts?.archived ?? detail?.sessions.map { $0.filter(\.isArchived).count }
    }
    private var archivedTitle: String {
        archivedCount.map(LAACopy.WorkProject.archivedCount) ?? LAACopy.WorkProject.showArchived
    }

    private func readMoreButton(archived: Bool) -> some View {
        Button { actions.readMore(archived) } label: {
            HStack(spacing: LAASpacing.x2) {
                Text(verbatim: LAACopy.WorkProject.readMore)
                if readingMore { ProgressView().controlSize(.small) }
            }
            .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
            .frame(minHeight: LAASpacing.minimumTouchTarget)
        }
        .buttonStyle(.plain)
        .disabled(readingMore)
        .accessibilityIdentifier(archived ? "laa.work.project.archived.more" : "laa.work.project.sessions.more")
    }

    @ViewBuilder private func sessionRows(_ rows: [LAAWorkSession], empty: String) -> some View {
        let ordered = LAAWorkSessionOrder.rows(rows)
        let all = ordered.pinned + ordered.recent
        if all.isEmpty {
            Text(verbatim: empty).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(all) { session in
                    Button { actions.openSession(session.id) } label: {
                        LAAWorkSessionRow(session: session, projectName: nil, options: options)
                            .padding(.leading, CGFloat(LAAWorkSessionOrder.depth(session, in: all)) * 16)
                    }
                    .buttonStyle(.plain)
                    if session.id != all.last?.id { Divider().overlay(LAAColor.separator).padding(.leading, 30) }
                }
            }
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
        }
    }

    // MARK: Instructions and files

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            sectionHeading(LAACopy.WorkProject.instructions, count: nil,
                           action: canChange ? (LAACopy.WorkProject.edit, "pencil", "laa.work.project.editInstructions", actions.editInstructions) : nil)
            let text = project.instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Button(action: actions.editInstructions) {
                Text(verbatim: text.isEmpty ? LAACopy.WorkProject.instructionsEmpty : text)
                    .laaTextStyle(.body)
                    .foregroundStyle(text.isEmpty ? LAAColor.secondaryText : LAAColor.text)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LAASpacing.x4)
                    .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canChange)
            .accessibilityIdentifier("work.project.instructions")
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            sectionHeading(LAACopy.WorkProject.files, count: nil,
                           action: uploading || !canChange ? nil : (LAACopy.WorkProject.add, "plus", "laa.work.project.addFile", actions.addFile))
            let files = project.files ?? []
            if uploading { Text(verbatim: LAACopy.WorkProject.sending).foregroundStyle(LAAColor.secondaryText) }
            if files.isEmpty && !uploading {
                Text(verbatim: LAACopy.WorkProject.filesEmpty).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            } else if !files.isEmpty {
                VStack(spacing: 0) {
                    ForEach(files) { file in
                        HStack(spacing: LAASpacing.x3) {
                            Image(systemName: Self.icon(file)).foregroundStyle(LAAColor.link).frame(width: 22)
                            Text(verbatim: file.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: LAASpacing.x2)
                            Text(verbatim: file.size.map(Self.size) ?? "").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                        .padding(.horizontal, LAASpacing.x4)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .background(LAAColor.surface)
                        .contextMenu {
                            Button(role: .destructive) { actions.removeFile(file) } label: {
                                Label { Text(verbatim: "Delete") } icon: { Image(systemName: "trash") }
                            }
                        }
                        if file.id != files.last?.id { Divider().overlay(LAAColor.separator).padding(.leading, 50) }
                    }
                }
                .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
                Text(verbatim: LAACopy.WorkProject.fileHint).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.project.files")
    }

    static func icon(_ file: LAAWorkProjectFile) -> String {
        let type = file.mimeType ?? UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType ?? ""
        if type.hasPrefix("image/") { return "photo" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: Shared

    private func sectionHeading(_ title: String, count: Int?,
                                action: (String, String, String, () -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
            Text(verbatim: title).laaTextStyle(.section).foregroundStyle(LAAColor.text)
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text(verbatim: "\(count)").laaTextStyle(.secondary).monospacedDigit().foregroundStyle(LAAColor.secondaryText)
            }
            Spacer(minLength: LAASpacing.x2)
            if let action {
                Button(action: action.3) {
                    Label { Text(verbatim: action.0) } icon: { Image(systemName: action.1) }
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                        .frame(minHeight: LAASpacing.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(action.2)
            }
        }
    }
}

// MARK: - Summary and note

/// "Done 3 / 7" on the meter. The counts per status are the group headings
/// below, so they are not repeated here.
struct LAAWorkProjectSummary: View {
    let board: LAAWorkRequirementBoard

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack(spacing: LAASpacing.x3) {
                LAAWorkProjectMeter(fraction: board.summary.fraction)
                Text(verbatim: LAACopy.WorkProject.done(board.summary.completed, of: board.summary.total))
                    .laaTextStyle(.secondary).monospacedDigit().foregroundStyle(LAAColor.text).fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: LAACopy.WorkProject.progressLabel(board.summary.completed, of: board.summary.total)))
            .accessibilityIdentifier("laa.work.project.summary.progress")
        }
    }
}

/// Monet's note on where the project stands and what comes next: a note, with
/// one teal rule on its left, never a box.
struct LAAWorkProjectNote: View {
    let text: String
    /// Three lines until the owner opens it: the page leads with the
    /// requirements, not the note (owner, 2026-11-26).
    @State private var expanded = false

    static let foldedLines = 3
    /// Long enough that three lines on the phone may not hold it.
    var folds: Bool { text.count > 90 || text.filter(\.isNewline).count >= Self.foldedLines }

    var body: some View {
        HStack(alignment: .top, spacing: LAASpacing.x3) {
            Rectangle().fill(LAAColor.link).frame(width: 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                HStack(spacing: LAASpacing.x2) {
                    Text(verbatim: LAACopy.WorkProject.note).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    Spacer(minLength: 0)
                    if folds {
                        Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LAAColor.secondaryText)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                                .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, -12)
                        .accessibilityLabel(Text(verbatim: LAACopy.WorkProject.note))
                        .accessibilityValue(Text(verbatim: expanded ? LAACopy.WorkProject.expandedValue : LAACopy.WorkProject.collapsedValue))
                        .accessibilityIdentifier("laa.work.project.note.toggle")
                    }
                }
                Text(verbatim: text).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                    .lineLimit(expanded || !folds ? nil : Self.foldedLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("laa.work.project.note.text")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laa.work.project.note")
    }
}

/// A short notice with a rule on its left: plum for a refused change, teal
/// for what the owner should know.
struct LAAWorkProjectNotice: View {
    let text: String
    let attention: Bool
    /// Offered beside a failed or stale reading; the text wraps, never cut.
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: LAASpacing.x3) {
            Rectangle().fill(attention ? LAAColor.attention : LAAColor.link).frame(width: 2).accessibilityHidden(true)
            Text(verbatim: text).laaTextStyle(.secondary)
                .foregroundStyle(attention ? LAAColor.attention : LAAColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button(action: retry) {
                    Text(verbatim: LAACopy.WorkTab.retry).laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                        .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -12)
                .accessibilityIdentifier("laa.work.project.retry")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Requirement row

/// One requirement in the list: its mark (where its state is changed) and a
/// one-line name. Selecting the row opens its page; nothing of the detail is
/// drawn here.
struct LAAWorkRequirementRow: View {
    let requirement: LAAWorkRequirement
    var busy = false
    var canChange = true
    let setStatus: (LAAWorkRequirementStatus) -> Void
    let withdraw: () -> Void
    let open: () -> Void

    private var done: Bool { requirement.status == .completed }

    var body: some View {
        HStack(alignment: .center, spacing: LAASpacing.x1) {
            LAAWorkRequirementStatusControl(requirement: requirement, busy: busy, canChange: canChange,
                                            setStatus: setStatus, withdraw: withdraw)
            Button(action: open) {
                Text(verbatim: LAAWorkRequirementName.short(requirement.title))
                    .laaTextStyle(.body).fontWeight(done ? .regular : .medium)
                    .foregroundStyle(done ? LAAColor.secondaryText : LAAColor.text)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: requirement.title))
            .accessibilityValue(Text(verbatim: requirement.status.label))
            .accessibilityIdentifier("laa.work.project.requirement.title.\(requirement.id)")
        }
        .opacity(busy ? 0.5 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laa.work.project.requirement.\(requirement.id)")
        .contextMenu { if canChange { LAAWorkRequirementMenu(requirement: requirement, setStatus: setStatus, withdraw: withdraw) } }
    }
}

/// The status mark, which is also the menu that changes the state.
struct LAAWorkRequirementStatusControl: View {
    let requirement: LAAWorkRequirement
    var busy = false
    var canChange = true
    let setStatus: (LAAWorkRequirementStatus) -> Void
    let withdraw: () -> Void

    var body: some View {
        Menu { LAAWorkRequirementMenu(requirement: requirement, setStatus: setStatus, withdraw: withdraw) } label: {
            LAAWorkStatusMark(status: requirement.status.mark)
                .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(busy || !canChange)
        .padding(.leading, -12)
        .accessibilityLabel(Text(verbatim: "\(requirement.status.label), \(requirement.addedByAI ? LAACopy.WorkProject.addedByAI : LAACopy.WorkProject.owner)"))
        .accessibilityHint(Text(verbatim: LAACopy.WorkProject.changeStatus))
        .accessibilityIdentifier("laa.work.project.requirement.status.\(requirement.id)")
    }
}

struct LAAWorkRequirementMenu: View {
    let requirement: LAAWorkRequirement
    let setStatus: (LAAWorkRequirementStatus) -> Void
    let withdraw: () -> Void

    var body: some View {
        Section(LAACopy.WorkProject.changeStatus) {
            ForEach(LAAWorkRequirementStatus.choices, id: \.self) { status in
                Button { if status != requirement.status { setStatus(status) } } label: {
                    if status == requirement.status {
                        Label { Text(verbatim: status.label) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(verbatim: status.label)
                    }
                }
                .accessibilityIdentifier("laa.work.project.requirement.set.\(status.rawValue)")
            }
        }
        Button(role: .destructive, action: withdraw) {
            Label { Text(verbatim: LAACopy.WorkProject.withdraw) } icon: { Image(systemName: "minus.circle") }
        }
        .accessibilityIdentifier("laa.work.project.requirement.withdraw")
    }
}
#endif
