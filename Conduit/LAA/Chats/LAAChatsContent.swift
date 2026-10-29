#if LAA_BUILD
import SwiftUI
import UIKit

struct LAAChatsContent: View {
    let snapshot: LAAChatsSnapshot
    var settingsAvailable: Bool
    var openPerson: (LAAChatsPerson) -> Void
    var openRoom: (GroupRoom) -> Void
    var openSession: (SessionSummary) -> Void
    var newChat: () -> Void
    var newGroup: () -> Void
    var openSettings: () -> Void
    var retry: () -> Void
    var searchChanged: () -> Void

    @State private var query = ""
    @State private var allEmployees = false
    @State private var allGroups = false
    @State private var allRecent = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var ciel: LAAChatsPerson? { snapshot.people.first { LAAStaff(profile: $0.profile) == .ciel } }
    private var employees: [LAAChatsPerson] {
        snapshot.people.filter { LAAStaff(profile: $0.profile) != .ciel && LAAChatsSearch.person($0, matches: query) }
    }
    private var rooms: [GroupRoom] { snapshot.rooms.filter { LAAChatsSearch.room($0, matches: query) } }
    private var sessions: [SessionSummary] {
        snapshot.sessions.filter { session in
            LAAChatsSearch.session(session, ownerName: person(for: session.profile ?? snapshot.activeProfile)?.name, matches: query)
        }
    }
    private var matchingCiel: LAAChatsPerson? {
        ciel.flatMap { LAAChatsSearch.person($0, matches: query) ? $0 : nil }
    }
    private var hasResults: Bool { matchingCiel != nil || !employees.isEmpty || !rooms.isEmpty || !sessions.isEmpty }
    private func person(for profile: String) -> LAAChatsPerson? {
        snapshot.people.first { $0.profile.caseInsensitiveCompare(profile) == .orderedSame }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                header
                if !snapshot.canCreateChat { note(LAACopy.chatsNewUnavailable) }
                search
                if searching && !hasResults {
                    searchEmpty
                } else {
                    if let ciel = matchingCiel { cielSection(ciel) }
                    if !searching || !employees.isEmpty { employeeSection }
                    if !searching || !rooms.isEmpty { groupSection }
                    if !searching || !sessions.isEmpty { recentSection }
                    if searching { searchIncomplete }
                }
                if settingsAvailable && !searching {
                    Button(action: openSettings) {
                        Label(LAACopy.chatsSettings, systemImage: "gearshape")
                            .laaTextStyle(.secondary)
                            .foregroundStyle(LAAColor.link)
                            .frame(minHeight: LAASpacing.minimumTouchTarget)
                    }
                    .accessibilityIdentifier("laa.chats.settings")
                }
            }
            .padding(.horizontal, LAASpacing.horizontal)
            .padding(.top, LAASpacing.x3)
            .padding(.bottom, LAASpacing.x8)
        }
        .background(LAAColor.background.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: query) { _, _ in searchChanged() }
        .accessibilityIdentifier("laa.chats.list")
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: LAASpacing.x3) {
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                Text(verbatim: "LAA")
                    .laaTextStyle(.section).fontWeight(.bold)
                    .foregroundStyle(LAAColor.link)
                Text(verbatim: LAACopy.chatsTitle)
                    .font(LAAType.screenTitle)
                    .foregroundStyle(LAAColor.text)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            Button(action: newChat) { newChatIcon }
            .disabled(!snapshot.canCreateChat)
            .accessibilityLabel(Text(verbatim: LAACopy.chatsNew))
            .accessibilityHint(Text(verbatim: snapshot.canCreateChat ? "" : LAACopy.chatsNewUnavailable))
            .accessibilityIdentifier("laa.chats.new")
        }
    }

    private var newChatSymbol: some View {
        Image(systemName: "plus")
            .laaTextStyle(.body).fontWeight(.medium)
            .foregroundStyle(LAAColor.link)
            .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
    }

    @ViewBuilder private var newChatIcon: some View {
        if reduceTransparency {
            newChatSymbol.background(LAAColor.surface, in: Circle())
                .overlay(Circle().stroke(LAAColor.separator, lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            GlassEffectContainer {
                newChatSymbol.glassEffect(.regular.interactive(), in: .circle)
            }
        } else {
            newChatSymbol.background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(LAAColor.separator, lineWidth: 1))
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
        .background(LAAColor.subtleSurface, in: RoundedRectangle(cornerRadius: LAARadius.card))
    }

    private func cielSection(_ ciel: LAAChatsPerson) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            sectionHeader(LAACopy.chatsCiel)
            Button { openPerson(ciel) } label: {
                personRow(ciel, size: 48)
                    .padding(LAASpacing.x3)
                    .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            }
            .buttonStyle(.plain)
            .disabled(!ciel.available)
            .accessibilityHint(Text(verbatim: ciel.available ? "" : LAACopy.chatsUnavailable))
            .accessibilityIdentifier("laa.chats.person.\(ciel.profile)")
            if !ciel.available { note(LAACopy.chatsUnavailable) }
        }
    }

    private var employeeSection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack {
                sectionHeader(LAACopy.chatsEmployees)
                Spacer()
                if employees.count > 3 && !searching {
                    moreButton(expanded: $allEmployees, id: "employees")
                }
            }
            if employees.isEmpty {
                note(LAACopy.chatsNoEmployees)
            } else {
                ForEach(Array((searching || allEmployees ? employees : Array(employees.prefix(3))))) { employee in
                    Button { openPerson(employee) } label: { personRow(employee, size: 40) }
                        .buttonStyle(.plain)
                        .disabled(!employee.available)
                        .accessibilityHint(Text(verbatim: employee.available ? "" : LAACopy.chatsUnavailable))
                        .accessibilityIdentifier("laa.chats.person.\(employee.profile)")
                }
            }
        }
    }

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack {
                sectionHeader(LAACopy.chatsGroups)
                Spacer()
                if rooms.count > 3 && !searching { moreButton(expanded: $allGroups, id: "groups") }
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
                loadNote(snapshot.groupsState, empty: LAACopy.chatsNoGroups, group: true)
            } else {
                ForEach(searching || allGroups ? rooms : Array(rooms.prefix(3))) { room in
                    Button { openRoom(room) } label: { roomRow(room) }
                        .buttonStyle(.plain)
                        .disabled(snapshot.groupsState == .offline)
                        .accessibilityIdentifier("laa.chats.group.\(room.roomID)")
                }
                if snapshot.groupsState != .ready { loadNote(snapshot.groupsState, empty: "", group: true) }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack {
                sectionHeader(LAACopy.chatsRecent)
                Spacer()
                if sessions.count > 3 && !searching { moreButton(expanded: $allRecent, id: "recent") }
            }
            if sessions.isEmpty {
                loadNote(snapshot.sessionsState, empty: LAACopy.chatsNoRecent, group: false)
            } else {
                let displayed = searching || allRecent ? sessions : Array(sessions.prefix(3))
                ForEach(Array(displayed.enumerated()), id: \.offset) { _, session in
                    Button { openSession(session) } label: { sessionRow(session) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("laa.chats.session.\(session.id)")
                }
                if snapshot.sessionsState != .ready { loadNote(snapshot.sessionsState, empty: "", group: false) }
            }
        }
    }

    private func personRow(_ person: LAAChatsPerson, size: CGFloat) -> some View {
        HStack(spacing: LAASpacing.x3) {
            avatar(profile: person.profile, name: person.name, size: size)
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                Text(verbatim: person.name).font(LAAType.employeeName).foregroundStyle(LAAColor.text)
                Text(verbatim: person.role).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            Spacer(minLength: LAASpacing.x2)
            Image(systemName: "chevron.right").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func roomRow(_ room: GroupRoom) -> some View {
        HStack(spacing: LAASpacing.x3) {
            Image(systemName: "number").laaTextStyle(.body).foregroundStyle(LAAColor.link)
                .frame(width: 40, height: 40).background(LAAColor.subtleSurface, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                Text(verbatim: room.name).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                let names = room.members.compactMap { $0.displayName ?? $0.profile ?? $0.handle }.joined(separator: ", ")
                if !names.isEmpty { Text(verbatim: names).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
            }
            Spacer(minLength: LAASpacing.x2)
            Image(systemName: "chevron.right").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        HStack(alignment: .top, spacing: LAASpacing.x3) {
            let profile = session.profile ?? snapshot.activeProfile
            avatar(profile: profile, name: person(for: profile)?.name ?? profile, size: 40)
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: session.title).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                    Spacer(minLength: LAASpacing.x2)
                    if !session.updatedLabel.isEmpty {
                        Text(verbatim: session.updatedLabel).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                }
                if let preview = session.preview, !preview.isEmpty {
                    Text(verbatim: preview).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func avatar(profile: String, name: String, size: CGFloat) -> some View {
        let assets = StaffAssetResolver.bundled.resolve(profile: profile)
        return Group {
            if let url = assets.avatar, let image = UIImage(contentsOfFile: url.path) {
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

    private func moreButton(expanded: Binding<Bool>, id: String) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            Text(verbatim: expanded.wrappedValue ? LAACopy.chatsSeeLess : LAACopy.chatsSeeAll)
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                .frame(minHeight: LAASpacing.minimumTouchTarget)
        }
        .accessibilityIdentifier("laa.chats.seeAll.\(id)")
    }

    private func note(_ message: String) -> some View {
        Text(verbatim: message).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var groupUnavailableReason: String {
        snapshot.groupsState == .unsupported ? LAACopy.chatsGroupUnsupported : LAACopy.chatsUnavailable
    }

    @ViewBuilder private func loadNote(_ state: LAAChatsLoadState, empty: String, group: Bool) -> some View {
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
        let state = LAAChatsSearch.emptySearchState(groups: snapshot.groupsState, sessions: snapshot.sessionsState)
        if state == .ready {
            note(LAACopy.chatsNoResults).accessibilityIdentifier("laa.chats.search.empty")
        } else {
            loadNote(state, empty: LAACopy.chatsNoResults, group: false)
        }
    }

    @ViewBuilder private var searchIncomplete: some View {
        let state = LAAChatsSearch.emptySearchState(groups: snapshot.groupsState, sessions: snapshot.sessionsState)
        if state != .ready { loadNote(state, empty: "", group: false) }
    }
}
#endif
