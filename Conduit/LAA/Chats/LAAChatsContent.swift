#if LAA_BUILD
import SwiftUI
import UIKit

struct LAAChatsContent: View {
    let snapshot: LAAChatsSnapshot
    var settingsAvailable: Bool
    /// The Mac's split list: the highlighted row and the menu bar's requests.
    var selection: LAAChatsListSelection? = nil
    var openPerson: (LAAChatsPerson) -> Void
    var callPerson: ((LAAChatsPerson) -> Void)? = nil
    var openRoom: (GroupRoom) -> Void
    var newChat: () -> Void
    var newGroup: () -> Void
    var openSettings: () -> Void
    var retry: () -> Void
    var searchChanged: () -> Void

    @Environment(\.laaDesktop) private var laaDesktop
    @State private var query = ""
    @State private var showSearch = false
    @State private var hoveredRow: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedRow: String?

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var monet: LAAChatsPerson? { snapshot.people.first { LAAStaff(profile: $0.profile) == .monet } }
    private var employees: [LAAChatsPerson] {
        snapshot.people.filter { LAAStaff(profile: $0.profile).map { [.monet, .monetDots, .monetUncensored].contains($0) } != true && LAAChatsSearch.person($0, matches: query) }
    }
    private var rooms: [GroupRoom] { snapshot.rooms.filter { LAAChatsSearch.room($0, matches: query) } }
    private var matchingMonet: LAAChatsPerson? {
        monet.flatMap { LAAChatsSearch.person($0, matches: query) ? $0 : nil }
    }
    private var hasResults: Bool { matchingMonet != nil || !monetVariants.isEmpty || !employees.isEmpty || !rooms.isEmpty }

    private var failure: String? {
        switch snapshot.groupsState {
        case .failed(let reason): return reason.isEmpty ? LAACopy.chatsIncomplete : reason
        case .offline: return LAACopy.chatsOffline
        case .unsupported: return LAACopy.chatsGroupUnsupported
        default: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // The Mac's window bar belongs to the whole window, so the
                // list's own new button sits by its heading there.
                HStack(alignment: .bottom) {
                    LAATabHeading(title: LAACopy.chatsTitle, identifier: "laa.chats.heading")
                    if laaDesktop {
                        Spacer()
                        newChatButton.buttonStyle(.borderless).foregroundStyle(LAAColor.link)
                    }
                }
                if showSearch { search }
                if let failure {
                    HStack(spacing: 8) {
                        Text(verbatim: failure).font(.system(size: 13)).foregroundStyle(LAAColor.secondaryText)
                        Spacer(minLength: 0)
                        if snapshot.groupsState != .unsupported {
                            Button("再試行", action: retry).font(.system(size: 13)).foregroundStyle(LAAColor.link).frame(minHeight: 44)
                        }
                    }
                }
                if searching && !hasResults {
                    searchEmpty
                } else {
                    if let monet, matchingMonet != nil || !monetVariants.isEmpty { monetSection(monet) }
                    if !searching || !employees.isEmpty { employeeSection }
                    if !searching || !rooms.isEmpty { groupSection }
                    if searching { searchIncomplete }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, LAASpacing.x3)
            .padding(.bottom, LAASpacing.x8)
        }
        .background(LAAColor.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if settingsAvailable { ToolbarItem(placement: .topBarLeading) { LAASettingsButton(action: openSettings) } }
            if !laaDesktop { ToolbarItem(placement: .topBarTrailing) { newChatButton } }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: query) { _, _ in searchChanged() }
        // The arrow keys walk the rows the list actually shows; Return opens
        // the focused one, so the list answers the keyboard the way the Mac's
        // other lists do. ⌘N, ⌘F and ⌘R come from the menu bar, which reads
        // the commands this section publishes below.
        .onKeyPress(.downArrow) { moveFocus(by: 1) }
        .onKeyPress(.upArrow) { moveFocus(by: -1) }
        .onKeyPress(.return) { openFocusedRow() }
        .laaMacSectionCommands(LAAMacSectionCommands(
            newTitle: LAACopy.chatsNewGroup,
            canCreate: snapshot.canCreateGroup,
            create: newGroup,
            canSearch: true,
            focusSearch: { showSearch = true; searchFocused = true },
            canReload: true,
            reload: retry
        ))
        .accessibilityIdentifier("laa.chats.list")
    }

    // MARK: Mac rows

    /// The rows a click or the arrow keys can reach, in the order shown.
    private var rowIDs: [String] {
        var ids: [String] = []
        if let monet = matchingMonet, monet.available { ids.append("person.\(monet.profile)") }
        ids += monetVariants.filter(\.available).map { "person.\($0.profile)" }
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

    /// The person or room a row id names, in the rows the list shows now.
    private func rowTarget(_ id: String) -> LAAChatsRowTarget? {
        if id.hasPrefix("person.") {
            let profile = String(id.dropFirst("person.".count))
            let people = ([matchingMonet].compactMap { $0 } + monetVariants + employees)
            return people.first { $0.profile == profile }.map(LAAChatsRowTarget.person)
        }
        let roomID = String(id.dropFirst("room.".count))
        return rooms.first { $0.roomID == roomID }.map(LAAChatsRowTarget.room)
    }

    private func openFocusedRow() -> KeyPress.Result {
        guard selection != nil else { return .ignored }
        guard let id = focusedRow ?? rowIDs.first(where: isSelected),
              let target = rowTarget(id) else { return .ignored }
        switch target {
        case .person(let person): openPerson(person)
        case .room(let room): openRoom(room)
        }
        return .handled
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
        LAASearchField(placeholder: LAACopy.chatsSearch, text: $query,
                       identifier: "laa.chats.search", focus: $searchFocused)
            .onAppear { searchFocused = true }
            .onKeyPress(.escape) {
                query = ""
                showSearch = false
                return .handled
            }
    }

    private var monetVariants: [LAAChatsPerson] {
        snapshot.people.filter { LAAStaff(profile: $0.profile).map { [.monetDots, .monetUncensored].contains($0) } == true && LAAChatsSearch.person($0, matches: query) }
    }

    private func monetSection(_ monet: LAAChatsPerson) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { openPerson(monet) } label: {
                    HStack(spacing: 12) {
                        avatar(profile: monet.profile, name: monet.name, size: 88)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: LAASpacing.x2) {
                                Text(verbatim: "Monet").font(.custom("Georgia", size: 22, relativeTo: .title3))
                                LAARoleBadge(role: "Secretary")
                                if let unread = snapshot.unreadByProfile[monet.profile], unread > 0 {
                                    unreadDot(unread)
                                }
                            }
                            if let preview = monet.lastMessage, !preview.isEmpty {
                                Text(verbatim: preview).font(.system(size: 15))
                                    .lineLimit(2).foregroundStyle(LAAColor.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(minHeight: 96).contentShape(Rectangle())
                }.buttonStyle(LAAListRowStyle())
                    .disabled(!monet.available)
                    .accessibilityIdentifier("laa.chats.person.\(monet.profile)")
                if let callPerson {
                    Button { callPerson(monet) } label: {
                        Image(systemName: "phone.fill").foregroundStyle(LAAColor.link).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).laaComposerGlass(in: Circle())
                        .disabled(!monet.available).accessibilityLabel("Monetに電話")
                        .accessibilityIdentifier("laa.chats.monet.call")
                }
            }
            ForEach(monetVariants) { person in
                Button { openPerson(person) } label: {
                    HStack(spacing: 12) {
                        avatar(profile: person.profile, name: person.name, size: 36)
                        Text(LAAStaff(profile: person.profile) == .monetDots ? "Monet · Dots" : "Monet · 無検閲")
                            .font(.custom("Georgia", size: 17, relativeTo: .body))
                        Spacer(minLength: 0)
                    }.frame(minHeight: 56).contentShape(Rectangle())
                }.buttonStyle(LAAListRowStyle()).disabled(!person.available)
                    .accessibilityIdentifier("laa.chats.person.\(person.profile)")
            }
        }.foregroundStyle(LAAColor.text)
    }

    private var employeeSection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            sectionHeader(LAACopy.chatsEmployees)
            if employees.isEmpty && snapshot.groupsState == .loading {
                LAALoadingDots()
            } else if employees.isEmpty {
                note(LAACopy.chatsNoEmployees)
            } else {
                VStack(spacing: 0) {
                ForEach(employees) { employee in
                    Button { openPerson(employee) } label: { personRow(employee, size: 48, selected: isSelected("person.\(employee.profile)")) }
                        .buttonStyle(LAAListRowStyle())
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
    }

    private var newChatButton: some View {
        Button(action: newGroup) {
            Image(systemName: "plus")
                .frame(minWidth: laaDesktop ? LAASpacing.minimumTouchTarget : nil,
                       minHeight: laaDesktop ? LAASpacing.minimumTouchTarget : nil)
        }
        .disabled(!snapshot.canCreateGroup)
        .accessibilityLabel(Text(verbatim: LAACopy.chatsNew))
        .accessibilityHint(Text(verbatim: snapshot.canCreateGroup ? "" : LAACopy.chatsNewUnavailable))
        .accessibilityIdentifier("laa.chats.new")
        .macTooltip(LAACopy.chatsNew)
    }

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            sectionHeader(LAACopy.chatsGroups)
            if rooms.isEmpty {
                loadNote(snapshot.groupsState, empty: LAACopy.chatsNoGroups)
            } else {
                VStack(spacing: 0) {
                ForEach(rooms) { room in
                    Button { openRoom(room) } label: { roomRow(room, selected: isSelected("room.\(room.roomID)")) }
                        .buttonStyle(LAAListRowStyle())
                        .disabled(snapshot.groupsState == .offline)
                        .accessibilityAddTraits(isSelected("room.\(room.roomID)") ? .isSelected : [])
                        .accessibilityIdentifier("laa.chats.group.\(room.roomID)")
                        .modifier(rowChrome("room.\(room.roomID)"))
                        .focused($focusedRow, equals: "room.\(room.roomID)")
                        .onHover(perform: hover("room.\(room.roomID)"))
                }
                }
                if snapshot.groupsState != .ready { loadNote(snapshot.groupsState, empty: "") }
            }
        }
    }

    private func personRow(_ person: LAAChatsPerson, size: CGFloat, selected: Bool = false) -> some View {
        HStack(spacing: LAASpacing.x3) {
            avatar(profile: person.profile, name: person.name, size: size)
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                HStack(spacing: 6) {
                    Text(verbatim: LAAChatPerson.name(person.name)).font(.custom("Georgia", size: 17, relativeTo: .body))
                        .foregroundStyle(selected ? LAAColor.link : LAAColor.text)
                    if let role = LAAChatPerson.role(profile: person.profile, existingRole: person.role) { LAARoleBadge(role: role) }
                }
                if let preview = person.lastMessage, !preview.isEmpty {
                    Text(verbatim: preview).font(.system(size: 13)).lineLimit(1).foregroundStyle(LAAColor.secondaryText)
                }
            }
            Spacer(minLength: LAASpacing.x2)
            VStack(alignment: .trailing, spacing: 8) {
                if let date = person.lastMessageAt { Text(date, style: .relative).font(.caption2).foregroundStyle(LAAColor.secondaryText) }
                if let unread = snapshot.unreadByProfile[person.profile], unread > 0 {
                    if unread == 1 { unreadDot(unread) } else { unreadBadge(unread) }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var rowHeight: CGFloat { selection == nil ? 64 : 72 }

    private func unreadDot(_ count: Int) -> some View {
        Circle().fill(LAAColor.link).frame(width: 8, height: 8)
            .accessibilityLabel(Text(verbatim: LAACopy.chatsUnread(count)))
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
                Text("\(room.members.count)人").font(.system(size: 13)).foregroundStyle(LAAColor.secondaryText)
            }
            Spacer(minLength: LAASpacing.x2)

        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
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
        .accessibilityHidden(true)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(LAAColor.text)
            .accessibilityAddTraits(.isHeader)
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
            LAALoadingDots()
        case .offline, .unsupported, .failed: EmptyView()
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

/// What a list row opens. The Mac's list selects the row's conversation in
/// the detail column; the phone pushes the same screen.
private enum LAAChatsRowTarget {
    case person(LAAChatsPerson)
    case room(GroupRoom)
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
                          : (hovering ? LAAColor.subtleSurface.opacity(0.7) : Color.clear))
            }
        }
    }
}
#endif
