#if LAA_BUILD
import SwiftUI
import UIKit

struct LAAChatsContent: View {
    let snapshot: LAAChatsSnapshot
    var settingsAvailable: Bool
    /// The Mac's split list: the highlighted row and the menu bar's requests.
    var selection: LAAChatsListSelection? = nil
    var openPerson: (LAAChatsPerson) -> Void
    var openRoom: (GroupRoom) -> Void
    /// A cron run's own conversation, from the scheduled section's history.
    var openRun: (SessionSummary) -> Void = { _ in }
    var newChat: () -> Void
    var newGroup: () -> Void
    var openSettings: () -> Void
    var retry: () -> Void
    var searchChanged: () -> Void

    @State private var query = ""
    @State private var hoveredRow: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedRow: String?

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var monet: LAAChatsPerson? { snapshot.people.first { LAAStaff(profile: $0.profile) == .monet } }
    private var employees: [LAAChatsPerson] {
        snapshot.people.filter { LAAStaff(profile: $0.profile) != .monet && LAAChatsSearch.person($0, matches: query) }
    }
    private var rooms: [GroupRoom] { snapshot.rooms.filter { LAAChatsSearch.room($0, matches: query) } }
    private var matchingMonet: LAAChatsPerson? {
        monet.flatMap { LAAChatsSearch.person($0, matches: query) ? $0 : nil }
    }
    private var hasResults: Bool { matchingMonet != nil || !employees.isEmpty || !rooms.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                LAATabHeading(title: LAACopy.chatsTitle)
                if !snapshot.canCreateChat { note(LAACopy.chatsNewUnavailable) }
                search
                if searching && !hasResults {
                    searchEmpty
                } else {
                    if let monet = matchingMonet { monetSection(monet) }
                    if !searching || !employees.isEmpty { employeeSection }
                    if !searching || !rooms.isEmpty { groupSection }
                    if !searching { scheduledSection }
                    if searching { searchIncomplete }
                }
            }
            .padding(.horizontal, LAASpacing.horizontal)
            .padding(.top, LAASpacing.x3)
            .padding(.bottom, LAASpacing.x8)
        }
        .background(LAAColor.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            // Creation sits on the leading edge so settings is the only
            // trailing item, in the same place as every other tab's.
            ToolbarItem(placement: .topBarLeading) {
                Button(action: newChat) { Image(systemName: "plus") }
                    .disabled(!snapshot.canCreateChat)
                    .accessibilityLabel(Text(verbatim: LAACopy.chatsNew))
                    .accessibilityHint(Text(verbatim: snapshot.canCreateChat ? "" : LAACopy.chatsNewUnavailable))
                    .accessibilityIdentifier("laa.chats.new")
            }
            if settingsAvailable { ToolbarItem(placement: .topBarTrailing) { LAASettingsButton(action: openSettings) } }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: query) { _, _ in searchChanged() }
        .onChange(of: selection?.focusSearch) { _, _ in
            guard selection != nil else { return }
            searchFocused = true
        }
        .onChange(of: selection?.reload) { _, _ in
            guard selection != nil else { return }
            retry()
        }
        .onChange(of: selection?.newChat) { _, _ in
            guard selection != nil, snapshot.canCreateChat else { return }
            newChat()
        }
        // The arrow keys walk the rows the list actually shows; Return opens
        // the focused one, because each row is a Button.
        .onKeyPress(.downArrow) { moveFocus(by: 1) }
        .onKeyPress(.upArrow) { moveFocus(by: -1) }
        .accessibilityIdentifier("laa.chats.list")
    }

    // MARK: Mac rows

    /// The rows a click or the arrow keys can reach, in the order shown.
    private var rowIDs: [String] {
        var ids: [String] = []
        if let monet = matchingMonet, monet.available { ids.append("person.\(monet.profile)") }
        ids += employees.filter(\.available).map { "person.\($0.profile)" }
        if snapshot.groupsState != .offline { ids += rooms.map { "room.\($0.roomID)" } }
        return ids
    }

    private func isSelected(_ id: String) -> Bool {
        guard let selection else { return false }
        if id.hasPrefix("person.") {
            return selection.roomID == nil && selection.profile == String(id.dropFirst("person.".count))
        }
        return selection.roomID == String(id.dropFirst("room.".count))
    }

    private func moveFocus(by delta: Int) -> KeyPress.Result {
        guard selection != nil else { return .ignored }
        let ids = rowIDs
        guard !ids.isEmpty else { return .ignored }
        guard let current = focusedRow, let index = ids.firstIndex(of: current) else {
            focusedRow = delta > 0 ? ids.first : ids.last
            return .handled
        }
        focusedRow = ids[min(max(index + delta, 0), ids.count - 1)]
        return .handled
    }

    private func rowChrome(_ id: String) -> some ViewModifier {
        LAAChatsRowChrome(active: selection != nil, selected: isSelected(id),
                          hovering: hoveredRow == id)
    }

    /// One row's pointer entry and exit. A row clears the highlight only if
    /// it still owns it, so moving between rows keeps the new one lit.
    private func hover(_ id: String) -> (Bool) -> Void {
        { inside in
            if inside { hoveredRow = id } else if hoveredRow == id { hoveredRow = nil }
        }
    }

    private var search: some View {
        HStack(spacing: LAASpacing.x3) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LAAColor.secondaryText)
                .accessibilityHidden(true)
            TextField("", text: $query, prompt: Text(verbatim: LAACopy.chatsSearch).foregroundStyle(LAAColor.secondaryText))
                .laaTextStyle(.body)
                .foregroundStyle(LAAColor.text)
                .focused($searchFocused)
                .submitLabel(.search)
                .accessibilityLabel(Text(verbatim: LAACopy.chatsSearch))
                .accessibilityIdentifier("laa.chats.search")
            if searching {
                Button { query = ""; searchFocused = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(LAAColor.secondaryText)
                        .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
                }
                .accessibilityLabel(Text(verbatim: "Clear search"))
            }
        }
        .padding(.leading, LAASpacing.x4)
        .padding(.trailing, LAASpacing.x1)
        .frame(minHeight: LAASpacing.minimumTouchTarget)
        .laaGlass(in: Capsule())
    }

    private func monetSection(_ monet: LAAChatsPerson) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            sectionHeader(LAACopy.chatsMonet)
            Button { openPerson(monet) } label: {
                personRow(monet, size: 48, selected: isSelected("person.\(monet.profile)"))
                    .padding(LAASpacing.x3)
                    .background(isSelected("person.\(monet.profile)") ? LAAColor.selectionFill : LAAColor.surface,
                                in: RoundedRectangle(cornerRadius: LAARadius.card))
            }
            .buttonStyle(.plain)
            .disabled(!monet.available)
            .accessibilityHint(Text(verbatim: monet.available ? "" : LAACopy.chatsUnavailable))
            .accessibilityAddTraits(isSelected("person.\(monet.profile)") ? .isSelected : [])
            .accessibilityIdentifier("laa.chats.person.\(monet.profile)")
            .focused($focusedRow, equals: "person.\(monet.profile)")
            .onHover(perform: hover("person.\(monet.profile)"))
            if !monet.available { note(LAACopy.chatsUnavailable) }
        }
    }

    private var employeeSection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            sectionHeader(LAACopy.chatsEmployees)
            if employees.isEmpty {
                note(LAACopy.chatsNoEmployees)
            } else {
                ForEach(employees) { employee in
                    Button { openPerson(employee) } label: { personRow(employee, size: 40, selected: isSelected("person.\(employee.profile)")) }
                        .buttonStyle(.plain)
                        .disabled(!employee.available)
                        .accessibilityHint(Text(verbatim: employee.available ? "" : LAACopy.chatsUnavailable))
                        .accessibilityAddTraits(isSelected("person.\(employee.profile)") ? .isSelected : [])
                        .accessibilityIdentifier("laa.chats.person.\(employee.profile)")
                        .modifier(rowChrome("person.\(employee.profile)"))
                        .focused($focusedRow, equals: "person.\(employee.profile)")
                        .onHover(perform: hover("person.\(employee.profile)"))
                }
            }
        }
    }

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack {
                sectionHeader(LAACopy.chatsGroups)
                Spacer()
                Button(action: newGroup) {
                    Image(systemName: "plus").laaTextStyle(.body)
                        .foregroundStyle(LAAColor.link)
                        .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
                }
                .disabled(!snapshot.canCreateGroup)
                .accessibilityLabel(Text(verbatim: LAACopy.chatsNewGroup))
                .accessibilityHint(Text(verbatim: snapshot.canCreateGroup ? "" : groupUnavailableReason))
                .accessibilityIdentifier("laa.chats.group.new")
            }
            if rooms.isEmpty {
                loadNote(snapshot.groupsState, empty: LAACopy.chatsNoGroups)
            } else {
                ForEach(rooms) { room in
                    Button { openRoom(room) } label: { roomRow(room, selected: isSelected("room.\(room.roomID)")) }
                        .buttonStyle(.plain)
                        .disabled(snapshot.groupsState == .offline)
                        .accessibilityAddTraits(isSelected("room.\(room.roomID)") ? .isSelected : [])
                        .accessibilityIdentifier("laa.chats.group.\(room.roomID)")
                        .modifier(rowChrome("room.\(room.roomID)"))
                        .focused($focusedRow, equals: "room.\(room.roomID)")
                        .onHover(perform: hover("room.\(room.roomID)"))
                }
                if snapshot.groupsState != .ready { loadNote(snapshot.groupsState, empty: "") }
            }
        }
    }

    private func personRow(_ person: LAAChatsPerson, size: CGFloat, selected: Bool = false) -> some View {
        HStack(spacing: LAASpacing.x3) {
            avatar(profile: person.profile, name: person.name, size: size)
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                Text(verbatim: person.name).font(LAAType.employeeName)
                    .foregroundStyle(selected ? LAAColor.link : LAAColor.text)
                Text(verbatim: person.role).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            Spacer(minLength: LAASpacing.x2)
            if let unread = snapshot.unreadByProfile[person.profile], unread > 0 {
                unreadBadge(unread)
            }
            Image(systemName: "chevron.right").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// A count, as the phone's chat lists show one: messages past the read
    /// watermark, or one when only the server's flag is known.
    private func unreadBadge(_ count: Int) -> some View {
        Text(verbatim: count > 99 ? "99+" : String(count))
            .laaTextStyle(.secondary).fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, LAASpacing.x2)
            .frame(minWidth: 22, minHeight: 22)
            .background(LAAColor.attention, in: Capsule())
            .accessibilityLabel(Text(verbatim: LAACopy.chatsUnread(count)))
    }

    private func roomRow(_ room: GroupRoom, selected: Bool = false) -> some View {
        HStack(spacing: LAASpacing.x3) {
            LAAGroupFaces(members: room.members, size: 40)
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                Text(verbatim: room.name).laaTextStyle(.body)
                    .foregroundStyle(selected ? LAAColor.link : LAAColor.text)
                let names = room.members.compactMap { $0.displayName ?? $0.profile ?? $0.handle }.joined(separator: ", ")
                if !names.isEmpty { Text(verbatim: names).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
            }
            Spacer(minLength: LAASpacing.x2)
            Image(systemName: "chevron.right").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func avatar(profile: String, name: String, size: CGFloat) -> some View {
        Group {
            if let image = LAAChatsAvatarCache.image(profile: profile) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(verbatim: String(name.prefix(1))).laaTextStyle(.body).foregroundStyle(LAAColor.link)
            }
        }
        .frame(width: size, height: size)
        .background(LAAColor.selectionFill)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(verbatim: title.uppercased())
            .laaTextStyle(.section).fontWeight(.bold).tracking(0.8)
            .foregroundStyle(LAAColor.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Scheduled jobs

    /// What this profile's jobs do, split by where their results land, with
    /// the next run and whether the job runs at all. Jobs stay Hermes' own:
    /// this only reads them, and the runs are the cron chats the list holds.
    /// An unread or failed read says so; only a read, empty answer says there
    /// are no scheduled jobs, so a display failure never reads as "stopped".
    private var scheduledSection: some View {
        let jobs = snapshot.cronJobs
        return VStack(alignment: .leading, spacing: LAASpacing.x2) {
            sectionHeader(LAACopy.chatsCron)
            if jobs.isEmpty {
                cronNote(snapshot.cronState)
            } else {
                ForEach(scheduledGroups, id: \.0) { group in
                    scheduledGroup(group.0, jobs: group.1)
                }
                if case .failed = snapshot.cronState { cronNote(.failed("")) }
            }
            if snapshot.cronSkipped > 0 {
                note(LAACopy.chatsCronPartial(snapshot.cronSkipped))
                    .accessibilityIdentifier("laa.chats.cron.partial")
            }
            if !snapshot.cronRuns.isEmpty { recentRuns }
        }
    }

    /// The scheduled section's own read state: loading, offline, or a failure
    /// with a way to ask again. Never the "no jobs" line.
    @ViewBuilder private func cronNote(_ state: LAAChatsLoadState) -> some View {
        switch state {
        case .ready: note(LAACopy.chatsCronNone)
        case .loading:
            HStack(spacing: LAASpacing.x2) { ProgressView(); note(LAACopy.chatsCronPending) }
        case .offline: note(LAACopy.chatsOffline)
        case .unsupported: note(LAACopy.chatsCronUnavailable)
        case .failed(let message):
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                note(message.isEmpty ? LAACopy.chatsCronStale : message)
                Button(LAACopy.chatsCronRetry, action: retry).laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                    .frame(minHeight: LAASpacing.minimumTouchTarget)
            }
        }
    }

    /// Jobs under the person whose chat receives them: a bot-chat target names
    /// its profile, and anything else runs in this connection's own conversation.
    private var scheduledGroups: [(String, [CronJob])] {
        var order: [String] = snapshot.people.map(\.profile).filter { !$0.isEmpty }
        var buckets: [String: [CronJob]] = [:]
        for job in snapshot.cronJobs {
            let profile = Self.deliveryProfile(job) ?? snapshot.cronProfile
            if !order.contains(profile) { order.append(profile) }
            buckets[profile, default: []].append(job)
        }
        return order.compactMap { profile in
            guard let jobs = buckets[profile], !jobs.isEmpty else { return nil }
            let name = Self.profileName(profile, people: snapshot.people)
            let sorted = jobs.sorted { ($0.nextRunAt ?? "~") < ($1.nextRunAt ?? "~") }
            return (name, sorted)
        }
    }

    private static func deliveryProfile(_ job: CronJob) -> String? {
        guard let deliver = job.deliver, deliver.hasPrefix("bot-chat:") else { return nil }
        let profile = String(deliver.dropFirst("bot-chat:".count))
        return profile.isEmpty ? nil : profile
    }

    private static func profileName(_ profile: String, people: [LAAChatsPerson]) -> String {
        if let person = people.first(where: { $0.profile == profile }) { return person.name }
        return profile.hasPrefix("laa-") ? String(profile.dropFirst("laa-".count)) : profile
    }

    private func scheduledGroup(_ title: String, jobs: [CronJob]) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: title).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            ForEach(jobs) { job in scheduledRow(job) }
        }
    }

    private func scheduledRow(_ job: CronJob) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            HStack(spacing: LAASpacing.x2) {
                Text(verbatim: job.displayName).laaTextStyle(.body).fontWeight(.medium)
                Spacer(minLength: LAASpacing.x2)
                Text(verbatim: job.statusLabel).laaTextStyle(.secondary)
                    .foregroundStyle(job.isActive ? LAAColor.link : LAAColor.secondaryText)
            }
            HStack(spacing: LAASpacing.x2) {
                if let schedule = CronScheduleText.describe(job, zoneLabel: snapshot.cronZoneLabel) {
                    Text(verbatim: schedule).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
                Spacer(minLength: LAASpacing.x2)
                if let next = Self.nextRunText(job.nextRunAt) {
                    Text(verbatim: "次回 \(next)").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
            }
        }
        .padding(LAASpacing.x3)
        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("laa.chats.cron.\(job.id)")
    }

    private var recentRuns: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: LAACopy.chatsCronRuns).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            ForEach(snapshot.cronRuns) { run in
                Button { openRun(run) } label: {
                    HStack(spacing: LAASpacing.x2) {
                        Text(verbatim: run.title).laaTextStyle(.body).lineLimit(1)
                        Spacer(minLength: LAASpacing.x2)
                        Text(verbatim: run.updatedLabel).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        Image(systemName: "chevron.right").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                    .padding(.vertical, LAASpacing.x1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("laa.chats.cronRun.\(run.id)")
            }
        }
    }

    /// Hermes' ISO instants, shown in the device's own words.
    private static func nextRunText(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: raw)
        if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: raw) }
        guard let date else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func note(_ message: String) -> some View {
        Text(verbatim: message).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var groupUnavailableReason: String {
        snapshot.groupsState == .unsupported ? LAACopy.chatsGroupUnsupported : LAACopy.chatsUnavailable
    }

    @ViewBuilder private func loadNote(_ state: LAAChatsLoadState, empty: String) -> some View {
        switch state {
        case .ready: note(empty)
        case .loading:
            HStack(spacing: LAASpacing.x2) { ProgressView(); note(LAACopy.chatsLoading) }
        case .offline: note(LAACopy.chatsOffline)
        case .unsupported: note(LAACopy.chatsGroupUnsupported)
        case .failed(let message):
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                note(message.isEmpty ? LAACopy.chatsIncomplete : message)
                Button(LAACopy.chatsRetry, action: retry).laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                    .frame(minHeight: LAASpacing.minimumTouchTarget)
            }
        }
    }

    @ViewBuilder private var searchEmpty: some View {
        let state = LAAChatsSearch.emptySearchState(groups: snapshot.groupsState)
        if state == .ready {
            note(LAACopy.chatsNoResults).accessibilityIdentifier("laa.chats.search.empty")
        } else {
            loadNote(state, empty: LAACopy.chatsNoResults)
        }
    }

    @ViewBuilder private var searchIncomplete: some View {
        let state = LAAChatsSearch.emptySearchState(groups: snapshot.groupsState)
        if state != .ready { loadNote(state, empty: "") }
    }
}

/// A group's members as overlapping faces in one avatar-sized square, so the
/// row shows who is in it: two faces on a diagonal, three in a cluster, the
/// third giving way to a count when there are more.
struct LAAGroupFaces: View {
    let members: [GroupMember]
    var size: CGFloat = 40

    private struct Face: Identifiable {
        let id: String
        let profile: String?
        let initial: String
        var more: Int = 0
    }

    private var faces: [Face] {
        let all = members.enumerated().map { index, member in
            Face(id: "\(index)", profile: member.profile,
                 initial: String((member.displayName ?? member.profile ?? member.handle ?? "?").prefix(1)))
        }
        guard all.count > 3 else { return all }
        var shown = Array(all.prefix(2))
        shown.append(Face(id: "more", profile: nil, initial: "", more: all.count - 2))
        return shown
    }

    var body: some View {
        let faces = faces
        ZStack(alignment: .topLeading) {
            switch faces.count {
            case 0:
                Image(systemName: "person.2.fill").laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                    .frame(width: size, height: size).background(LAAColor.subtleSurface, in: Circle())
            case 1:
                face(faces[0], diameter: size)
            case 2:
                let diameter = size * 0.7
                face(faces[0], diameter: diameter)
                face(faces[1], diameter: diameter).offset(x: size - diameter, y: size - diameter)
            default:
                let diameter = size * 0.6
                face(faces[0], diameter: diameter).offset(x: (size - diameter) / 2, y: 0)
                face(faces[1], diameter: diameter).offset(x: 0, y: size - diameter)
                face(faces[2], diameter: diameter).offset(x: size - diameter, y: size - diameter)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func face(_ face: Face, diameter: CGFloat) -> some View {
        Group {
            if face.more > 0 {
                Text(verbatim: "+\(face.more)").font(.system(size: diameter * 0.4, weight: .semibold))
                    .foregroundStyle(LAAColor.link)
            } else if let image = face.profile.flatMap({ LAAChatsAvatarCache.image(profile: $0) }) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(verbatim: face.initial).font(.system(size: diameter * 0.45, weight: .medium))
                    .foregroundStyle(LAAColor.link)
            }
        }
        .frame(width: diameter, height: diameter)
        .background(LAAColor.selectionFill)
        .clipShape(Circle())
        // The page's own colour as a ring, so overlapping faces stay apart.
        .overlay(Circle().stroke(LAAColor.background, lineWidth: 1.5))
    }
}

/// Staff art is bundled with the app and cannot change during its lifetime.
/// Resolve each profile once and reuse the bounded, downsampled avatar cache
/// instead of reading and decoding a 512px file on every chat-list redraw.
@MainActor
private enum LAAChatsAvatarCache {
    private static var avatarURLs: [String: URL] = [:]
    private static var lookedUp: Set<String> = []

    static func image(profile: String) -> UIImage? {
        let key = profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard LAAStaff(profile: key) != nil else { return nil }
        if lookedUp.insert(key).inserted {
            avatarURLs[key] = StaffAssetResolver.bundled.resolve(profile: key).avatar
        }
        guard let url = avatarURLs[key] else { return nil }
        return ProfileAvatarImageCache.image(at: url)
    }
}

/// Mac only: a row's selected and hovered fill. `active` is false on the
/// phone, where the list draws neither, so the row is untouched there.
private struct LAAChatsRowChrome: ViewModifier {
    let active: Bool
    let selected: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        content.background {
            if active {
                RoundedRectangle(cornerRadius: LAARadius.card)
                    .fill(selected ? LAAColor.selectionFill
                          : (hovering ? LAAColor.subtleSurface : Color.clear))
            }
        }
    }
}
#endif
