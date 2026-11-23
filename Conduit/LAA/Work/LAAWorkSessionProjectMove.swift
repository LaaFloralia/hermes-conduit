#if LAA_BUILD
import SwiftUI

/// Every Session belongs to a Project (owner, 2026-11-23): a new one is
/// started inside the project chosen for it, and an existing one can be
/// moved to another (`PATCH /v1/sessions/{id}` with only `projectId`).
enum LAAWorkSessionProjects {
    /// The Bridge's reserved project for Sessions started without one.
    static let unfiledID = "prj_000000000000"
    /// The project last opened or started in, offered first next time.
    static let lastKey = "laa.work.lastProject"

    /// Remembers the project the owner opened, so the next new Session
    /// starts in it.
    static func noteOpened(_ id: String, defaults: UserDefaults = .standard) {
        guard id.hasPrefix("prj_") else { return }
        defaults.set(id, forKey: lastKey)
    }

    /// The projects a Session can go into, in the list's order, with the
    /// reserved 未分類 last.
    static func choices(_ projects: [LAAWorkProject]) -> [LAAWorkProject] {
        let active = projects.filter { !$0.isArchived }
        return active.filter { $0.id != unfiledID } + active.filter { $0.id == unfiledID }
    }

    /// The project a new Session starts in: the one it was opened from, else
    /// the last one used, else none, and the owner is asked to choose.
    static func initialID(given: String, last: String, in projects: [LAAWorkProject]) -> String {
        let ids = Set(choices(projects).map(\.id))
        if ids.contains(given) { return given }
        if ids.contains(last) { return last }
        return ""
    }

    /// A project the list did not have before: the one just created.
    static func created(before: [LAAWorkProject], after: [LAAWorkProject]) -> LAAWorkProject? {
        let known = Set(before.map(\.id))
        return choices(after).first { !known.contains($0.id) }
    }

    struct Move: Encodable { let projectId: String }

    @MainActor static func move(_ session: LAAWorkSession, to project: LAAWorkProject,
                                bridge: LAABridgeSession) async throws -> LAAWorkSession {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let body = try encoder.encode(Move(projectId: project.id))
        return try await LAAWorkHTTP.write(bridge, path: "/v1/sessions/\(session.id)", body: body,
                                           key: LAABridgeIdempotencyKey(), method: "PATCH")
    }

    /// Why a move was refused, in one line. A Bridge from before projects
    /// were required knows no `projectId` change and asks for the fields it
    /// does know.
    static func failure(_ error: Error) -> String {
        guard let error = error as? LAABridgeHTTPError else { return "プロジェクトを変更できませんでした。" }
        if isOlderBridge(error) { return "MacのLAAアプリを最新にすると使えます。" }
        return LAAWorkHTTP.message(error)
    }

    static func isOlderBridge(_ error: LAABridgeHTTPError) -> Bool {
        error.status == 405 || (error.status == 400 && (error.message ?? "").contains("favorite, archived"))
    }
}

/// 「プロジェクトを変更」: one item in a Session's operations menu, opening the
/// projects it can move to, the current one checked.
struct LAAWorkProjectMoveMenu: View {
    let session: LAAWorkSession
    let projects: [LAAWorkProject]
    let move: (LAAWorkProject) -> Void

    var body: some View {
        Menu {
            ForEach(LAAWorkSessionProjects.choices(projects)) { project in
                Button { move(project) } label: {
                    if project.id == session.projectId {
                        Label { Text(verbatim: project.name) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(verbatim: project.name)
                    }
                }
                .disabled(project.id == session.projectId)
                .accessibilityIdentifier("work.session.project.\(project.id)")
            }
        } label: {
            Label { Text(verbatim: "プロジェクトを変更") } icon: { Image(systemName: "folder") }
        }
        .disabled(LAAWorkSessionProjects.choices(projects).count < 2 && session.projectId != nil)
        .accessibilityIdentifier("work.session.project")
    }
}
#endif
