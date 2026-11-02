#if LAA_BUILD
import SwiftUI
import UIKit

struct LAAChatsContent: View {
    let snapshot: LAAChatsSnapshot
    var settingsAvailable: Bool
    var openPerson: (LAAChatsPerson) -> Void
    var openRoom: (GroupRoom) -> Void
    var newChat: () -> Void
    var newGroup: () -> Void
    var openSettings: () -> Void
    var retry: () -> Void
    var searchChanged: () -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var ciel: LAAChatsPerson? { snapshot.people.first { LAAStaff(profile: $0.profile) == .ciel } }
    private var employees: [LAAChatsPerson] {
        snapshot.people.filter { LAAStaff(profile: $0.profile) != .ciel && LAAChatsSearch.person($0, matches: query) }
    }
    private var rooms: [GroupRoom] { snapshot.rooms.filter { LAAChatsSearch.room($0, matches: query) } }
    private var matchingCiel: LAAChatsPerson? {
        ciel.flatMap { LAAChatsSearch.person($0, matches: query) ? $0 : nil }
    }
    private var hasResults: Bool { matchingCiel != nil || !employees.isEmpty || !rooms.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                LAATabHeading(title: LAACopy.chatsTitle)
                if !snapshot.canCreateChat { note(LAACopy.chatsNewUnavailable) }
                search
                if searching && !hasResults {
                    searchEmpty
                } else {
                    if let ciel = matchingCiel { cielSection(ciel) }
                    if !searching || !employees.isEmpty { employeeSection }
                    if !searching || !rooms.isEmpty { groupSection }
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
            // New chat and Settings share one glass in the bar, as in the
            // system's Messages.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: newChat) { Image(systemName: "plus") }
                    .disabled(!snapshot.canCreateChat)
                    .accessibilityLabel(Text(verbatim: LAACopy.chatsNew))
                    .accessibilityHint(Text(verbatim: snapshot.canCreateChat ? "" : LAACopy.chatsNewUnavailable))
                    .accessibilityIdentifier("laa.chats.new")
                if settingsAvailable { LAASettingsButton(action: openSettings) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: query) { _, _ in searchChanged() }
        .accessibilityIdentifier("laa.chats.list")
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
            sectionHeader(LAACopy.chatsEmployees)
            if employees.isEmpty {
                note(LAACopy.chatsNoEmployees)
            } else {
                ForEach(employees) { employee in
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
                    Button { openRoom(room) } label: { roomRow(room) }
                        .buttonStyle(.plain)
                        .disabled(snapshot.groupsState == .offline)
                        .accessibilityIdentifier("laa.chats.group.\(room.roomID)")
                }
                if snapshot.groupsState != .ready { loadNote(snapshot.groupsState, empty: "") }
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
            LAAGroupFaces(members: room.members, size: 40)
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
            } else if let url = face.profile.flatMap({ StaffAssetResolver.bundled.resolve(profile: $0).avatar }),
                      let image = UIImage(contentsOfFile: url.path) {
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
#endif
