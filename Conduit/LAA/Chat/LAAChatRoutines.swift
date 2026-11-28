#if LAA_BUILD
import CryptoKit
import LAAKit
import SwiftUI

/// The two threads of one employee's chat (D-47, 2026-11-28): the
/// conversation, and the reports their routines (cron jobs) left in it.
/// A chat with no report shows no switch.
enum LAAChatThread: String, Hashable, CaseIterable {
    case chat, routines

    var title: String {
        switch self {
        case .chat: String("Chat")
        case .routines: String("Routines")
        }
    }
}

/// One routine report of the open chat, read from its transcript row.
struct LAARoutineReport: Identifiable, Equatable {
    let message: ChatMessage
    /// Stable across compaction's second copy and a reload: the row's
    /// time and text (`PersistedTranscriptWindow.cronReportKey`), hashed.
    let id: String
    let title: String
    let preview: String

    init?(_ message: ChatMessage) {
        guard message.isCronReport, let report = MessageNormalizer.cronReport(message.content) else { return nil }
        self.message = message
        id = Self.key(message)
        title = report.title
        preview = Self.preview(report.body)
    }

    static func key(_ message: ChatMessage) -> String {
        let digest = SHA256.hash(data: Data(PersistedTranscriptWindow.cronReportKey(message).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The chat's reports, newest first.
    static func reports(in targets: [ChatMessageScrollTarget]) -> [LAARoutineReport] {
        targets.reversed().compactMap { $0.isCronReport ? LAARoutineReport($0.message) : nil }
    }

    /// The body's first line of words: no picture or file line, no
    /// Markdown marks in front.
    static func preview(_ body: String) -> String {
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("MEDIA:") || line.hasPrefix("```") || line.hasPrefix("@") { continue }
            let text = line.drop(while: { "#>*-+ ".contains($0) }).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return ""
    }
}

/// Which reports this device has opened, per chat, and the report a
/// tapped notification asked to show. Kept in UserDefaults on the device;
/// read receipts and notifications are not changed by it.
@MainActor
final class LAARoutineReportStore: ObservableObject {
    static let shared = LAARoutineReportStore()
    static let defaultsKey = "laa.chat.routineReports.read"
    /// Ids kept per chat; the oldest go first.
    static let keptPerChat = 400

    struct Route: Equatable {
        let title: String
        let at: Date
    }

    @Published private(set) var read: [String: [String]]
    /// A routine report's notification was tapped: the chat it opens lands
    /// on Routines, on the newest report of that routine.
    @Published private(set) var route: Route?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        read = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] ?? [:]
    }

    static func scope(_ key: ChatScrollSessionKey) -> String { key.profile + "/" + key.sessionID }

    func isRead(_ report: LAARoutineReport, in scope: String) -> Bool {
        read[scope]?.contains(report.id) == true
    }

    func unreadCount(_ reports: [LAARoutineReport], in scope: String) -> Int {
        let seen = Set(read[scope] ?? [])
        return reports.reduce(0) { $0 + (seen.contains($1.id) ? 0 : 1) }
    }

    func markRead(_ report: LAARoutineReport, in scope: String) {
        var ids = read[scope] ?? []
        guard !ids.contains(report.id) else { return }
        ids.append(report.id)
        if ids.count > Self.keptPerChat { ids.removeFirst(ids.count - Self.keptPerChat) }
        read[scope] = ids
        defaults.set(read, forKey: Self.defaultsKey)
    }

    /// The routine a notification names in its title (the notifier's
    /// `Cron job "<name>"`). A failure notice or any other title is no route.
    static func routineName(notificationTitle title: String) -> String? {
        let prefix = "Cron job \"", suffix = "\""
        guard title.hasPrefix(prefix), title.hasSuffix(suffix), title.count > prefix.count + suffix.count - 1 else { return nil }
        let name = String(title.dropFirst(prefix.count).dropLast(suffix.count))
        return name.isEmpty || name.contains("\"") ? nil : name
    }

    func noteTappedNotification(title: String, now: Date = Date()) {
        route = Self.routineName(notificationTitle: title).map { Route(title: $0, at: now) }
    }

    /// The report the pending route points at in this chat, once; nil when
    /// the chat has none of that routine or the tap is over two minutes old.
    func takeRoute(in reports: [LAARoutineReport], now: Date = Date()) -> LAARoutineReport? {
        guard let route else { return nil }
        guard now.timeIntervalSince(route.at) < 120 else {
            self.route = nil
            return nil
        }
        guard let report = reports.first(where: { $0.title == route.title }) else { return nil }
        self.route = nil
        return report
    }

    #if DEBUG
    func resetForTesting() {
        read = [:]; route = nil
        defaults.removeObject(forKey: Self.defaultsKey)
    }
    #endif
}

/// The switch above an employee's chat: Chat, and Routines with the
/// number of reports not opened yet.
struct LAAChatThreadSwitch: View {
    @Binding var thread: LAAChatThread
    let unread: Int

    var body: some View {
        LAASegmentedControl(
            values: LAAChatThread.allCases,
            selection: $thread,
            title: \.title,
            identifier: { "chat.thread." + $0.rawValue },
            count: { $0 == .routines && unread > 0 ? unread : nil }
        )
        .frame(maxWidth: LAAChatRoutinesMetrics.switchWidth)
        .padding(.horizontal, LAASpacing.horizontal)
        .padding(.top, LAASpace.s8)
        .padding(.bottom, LAASpace.s4)
        .frame(maxWidth: .infinity)
    }
}

enum LAAChatRoutinesMetrics {
    static let switchWidth: CGFloat = 280 * LAAType.platformScale
    static let unreadDot: CGFloat = 6
    /// The chat's coordinate space, for where the switch ends.
    static let space = "laa.chat.threads"
}

/// Routines: the chat's reports, newest first, one ruled row each; a row
/// opens its report in the card the chat drew it in.
struct LAAChatRoutinesView: View {
    let reports: [LAARoutineReport]
    let scope: String
    @Binding var openedID: String?
    let gatewayResolver: GatewayMediaDataURLResolver?
    @ObservedObject private var store = LAARoutineReportStore.shared

    var body: some View {
        Group {
            if let openedID, let report = reports.first(where: { $0.id == openedID }) {
                detail(report)
            } else {
                list
            }
        }
        .background(LAAColor.background)
        .accessibilityIdentifier("chat.routines")
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(reports) { report in
                    row(report)
                    Rectangle().fill(LAAColor.separator).frame(height: 1).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, LAASpacing.horizontal)
            .padding(.top, LAASpace.s8)
            .padding(.bottom, LAASpace.s32)
        }
        // On the scroll view, as the transcript's: inside it the column's
        // reader has no height and the rows would overflow it.
        .readableChatColumn()
    }

    private func row(_ report: LAARoutineReport) -> some View {
        let unread = !store.isRead(report, in: scope)
        return Button { open(report) } label: {
            HStack(alignment: .firstTextBaseline, spacing: LAASpace.s8) {
                Circle()
                    .fill(unread ? LAAColor.link : Color.clear)
                    .frame(width: LAAChatRoutinesMetrics.unreadDot, height: LAAChatRoutinesMetrics.unreadDot)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + LAASpace.s4 }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LAASpace.s4) {
                    HStack(alignment: .firstTextBaseline, spacing: LAASpace.s8) {
                        Text(verbatim: report.title)
                            .laaTextStyle(.body).fontWeight(unread ? .semibold : .regular)
                            .foregroundStyle(LAAColor.text)
                            .lineLimit(1)
                        Spacer(minLength: LAASpace.s8)
                        if let time = MessageTimestampFormatter.displayString(for: report.message.timestamp) {
                            Text(verbatim: time)
                                .laaTextStyle(.secondary).monospacedDigit()
                                .foregroundStyle(LAAColor.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    if !report.preview.isEmpty {
                        Text(verbatim: report.preview)
                            .laaTextStyle(.secondary)
                            .foregroundStyle(LAAColor.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, LAASpace.s12)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: unread ? "Unread" : ""))
        .accessibilityIdentifier("chat.routines.row." + report.id)
    }

    private func detail(_ report: LAARoutineReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpace.s8) {
                Button { openedID = nil } label: {
                    Image(systemName: "chevron.left")
                        .laaTextStyle(.body).fontWeight(.medium)
                        .foregroundStyle(LAAColor.link)
                        .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget,
                               alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Back"))
                .accessibilityIdentifier("chat.routines.back")
                SystemBubble(message: report.message, gatewayResolver: gatewayResolver)
                    .accessibilityIdentifier("chat.routines.report")
            }
            .padding(.horizontal, LAASpacing.horizontal)
            .padding(.bottom, LAASpace.s32)
        }
        .readableChatColumn()
        .onAppear { store.markRead(report, in: scope) }
    }

    private func open(_ report: LAARoutineReport) {
        store.markRead(report, in: scope)
        openedID = report.id
    }
}
#endif
