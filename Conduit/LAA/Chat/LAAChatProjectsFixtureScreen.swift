#if LAA_BUILD && DEBUG
import LAAKit
import SwiftUI

struct LAAChatProjectsFixtureScreen: View {
    var showsGlassTabBar = false
    @State private var store = LAAChatProjectStore(fileURL: nil)
    @State private var selected: UUID?
    @State private var create = false
    @State private var created: UUID?

    var body: some View {
        LAAChatsContent(snapshot: .init(people: [], rooms: [], groupsState: .ready, canCreateChat: false,
                                       canCreateGroup: false), settingsAvailable: false,
                        openPerson: { _ in }, openRoom: { _ in }, newChat: {}, newGroup: {}, openSettings: {},
                        retry: {}, searchChanged: {}, publishesMacCommands: false,
                        projects: store.projects, openProject: { selected = $0 }, newProject: { create = true })
            .laaTabBarClearance(showsGlassTabBar)
            .navigationDestination(item: $selected) { id in
                LAAChatProjectDetail(store: store, id: id, runtime: LAAChatProjectFixtureRuntime(), showsGlassTabBar: showsGlassTabBar)
            }
            .sheet(isPresented: $create, onDismiss: { selected = created; created = nil }) {
                LAAChatProjectEditor(store: store) { created = $0 }
            }
    }
}
#endif
