#if LAA_BUILD
import SwiftUI

/// Work › Sessions. Sessions start in /Users/laa; favourites stay on top,
/// swiping a row archives it (trailing) or pins it (leading).
struct LAAWorkSessionsSection: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let refreshID: Int

    @ObservedObject private var linkRequest = LAAWorkLinkRequest.shared
    @State private var search = ""
    @State private var linkedSessionID: String?
    @State private var sessions: [LAAWorkSession] = []
    @State private var projects: [LAAWorkProject] = []
    @State private var options: LAAWorkSessionOptions?
    @State private var showArchived = false
    @State private var showLauncher = false
    @State private var opened: LAAWorkSession?
    @State private var failure: String?
    @State private var loading = false
    @State private var openRow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            LAAWorkPrimaryButton(title: "新しいセッション", systemImage: "plus") { showLauncher = true }
                .accessibilityIdentifier("work.sessions.new")
            if let failure { LAAWorkFailure(text: failure) { Task { await load() } } }
            if loading && sessions.isEmpty { ProgressView().accessibilityLabel(Text(verbatim: "読み込み中")) }

            TextField("", text: $search, prompt: Text(verbatim: "セッションを検索"))
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("work.sessions.search")
            let visible = LAAWorkSessionOrder.rows(filteredSessions)
            if visible.pinned.isEmpty && visible.recent.isEmpty && !loading && failure == nil {
                Text(verbatim: showArchived ? "アーカイブしたセッションはありません。" : "セッションはまだありません。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .padding(.vertical, LAASpacing.x4)
            }
            if !visible.pinned.isEmpty { group("ピン留め", visible.pinned) }
            if !visible.recent.isEmpty { group(showArchived ? "アーカイブ" : "最近", visible.recent) }

            Button {
                showArchived.toggle()
                Task { await load() }
            } label: {
                Label { Text(verbatim: showArchived ? "最近のセッションへ戻る" : "アーカイブを表示") }
                    icon: { Image(systemName: showArchived ? "arrow.uturn.left" : "archivebox") }
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                    .frame(minHeight: LAASpacing.minimumTouchTarget)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("work.sessions.archiveToggle")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.sessions")
        .navigationDestination(item: $opened) { session in
            LAAWorkSessionDetail(id: session.id, projects: projects, workspaces: [], drafts: drafts)
        }
        .navigationDestination(item: $linkedSessionID) { id in
            LAAWorkSessionDetail(id: id, projects: projects, workspaces: [], drafts: drafts)
        }
        .task(id: linkRequest.generation) { await openLinkedSession() }
        .sheet(isPresented: $showLauncher) {
            LAAWorkSessionLauncher(projects: projects, options: options, drafts: drafts) { created in
                showLauncher = false
                showArchived = false
                Task {
                    await load()
                    opened = created
                }
            }
            .environmentObject(bridge)
        }
        .task(id: "\(bridge.revision)-\(refreshID)") {
            sessions = LAAWorkSessionCache.read([LAAWorkSession].self, store: drafts, device: bridge.deviceID, target: "list") ?? []
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await load()
            }
        }
    }

    private func group(_ title: String, _ rows: [LAAWorkSession]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title).laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                .padding(.bottom, LAASpacing.x2)
            VStack(spacing: 0) {
                ForEach(rows) { session in
                    LAAWorkSwipeRow(id: session.id, openID: $openRow,
                                    leading: .init(title: session.isArchived ? "戻す" : "アーカイブ",
                                                   systemImage: session.isArchived ? "tray.and.arrow.up" : "archivebox",
                                                   tint: LAAColor.attention) { Task { await update(session, archived: !session.isArchived) } },
                                    trailing: .init(title: session.isFavorite ? "ピン解除" : "ピン留め",
                                                    systemImage: session.isFavorite ? "pin.slash" : "pin",
                                                    tint: LAAColor.link) { Task { await update(session, favorite: !session.isFavorite) } }) {
                        Button { opened = session } label: {
                            LAAWorkSessionRow(session: session, projectName: projectName(session.projectId), options: options)
                                .padding(.leading, CGFloat(LAAWorkSessionOrder.depth(session, in: sessions)) * 16)
                        }
                        .buttonStyle(.plain)
                    }
                    .contextMenu {
                        Button { Task { await update(session, favorite: !session.isFavorite) } } label: {
                            Label { Text(verbatim: session.isFavorite ? "ピン解除" : "ピン留め") } icon: { Image(systemName: "pin") }
                        }
                        Button { Task { await update(session, archived: !session.isArchived) } } label: {
                            Label { Text(verbatim: session.isArchived ? "アーカイブから戻す" : "アーカイブ") } icon: { Image(systemName: "archivebox") }
                        }
                    }
                    if session.id != rows.last?.id { Divider().overlay(LAAColor.separator).padding(.leading, 30) }
                }
            }
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
        }
    }

    private var filteredSessions: [LAAWorkSession] {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return sessions }
        var ids = Set(sessions.filter { ($0.name + " " + ($0.observed?.model ?? $0.requested?.model ?? "")).localizedCaseInsensitiveContains(search) }.map(\.id))
        for session in sessions where ids.contains(session.id) {
            var parent = session.parentId
            var seen = Set<String>()
            while let id = parent, seen.insert(id).inserted, let row = sessions.first(where: { $0.id == id }) {
                ids.insert(id); parent = row.parentId
            }
        }
        return sessions.filter { ids.contains($0.id) }
    }

    private func projectName(_ id: String?) -> String? {
        guard let id else { return nil }
        return projects.first { $0.id == id }?.name
    }

    @MainActor private func openLinkedSession() async {
        guard let target = linkRequest.sessionTarget else { return }
        if let id = linkRequest.sessionID { linkedSessionID = id; return }
        if let known = sessions.first(where: { $0.delegateSessionId == target }) { linkedSessionID = known.id; return }
        do {
            let rows: [LAAWorkSession] = try await LAAWorkPaging.all(bridge, "/v1/sessions", query: [URLQueryItem(name: "scope", value: "all")])
            guard !Task.isCancelled, linkRequest.sessionTarget == target else { return }
            guard let row = rows.first(where: { $0.delegateSessionId == target }) else { failure = "リンク先の会話を確認できません。"; return }
            linkedSessionID = row.id
        } catch { if !Task.isCancelled { failure = "リンク先の会話を読み取れません。再接続して確認してください。" } }
    }

    @MainActor private func load() async {
        guard bridge.status == .paired else { return }
        loading = true
        defer { loading = false }
        do {
            let query = showArchived ? [URLQueryItem(name: "archived", value: "only")] : []
            async let page: [LAAWorkSession] = LAAWorkPaging.all(bridge, "/v1/sessions", query: query)
            async let projectPage: [LAAWorkProject] = LAAWorkPaging.all(bridge, "/v1/projects")
            let (loaded, loadedProjects) = try await (page, projectPage)
            guard !Task.isCancelled else { return }
            // An older Bridge ignores the filters: keep worktree and archived rows out here too.
            let visible = loaded.filter { $0.isArchived == showArchived }
            sessions = showArchived ? visible : LAAWorkSessionScope.default(visible, projects: loadedProjects)
            LAAWorkSessionCache.save(sessions, store: drafts, device: bridge.deviceID, target: showArchived ? "archived" : "list")
            projects = loadedProjects
            failure = nil
        } catch is CancellationError {
            return
        } catch let error as LAABridgeError {
            failure = error.japaneseText
        } catch {
            failure = "Macからの応答を読み取れませんでした。"
        }
        if options == nil { options = try? await bridge.read("/v1/session-options") }
    }

    @MainActor private func update(_ session: LAAWorkSession, favorite: Bool? = nil, archived: Bool? = nil) async {
        openRow = nil
        struct Change: Encodable { let favorite: Bool?; let archived: Bool? }
        guard let body = try? JSONEncoder().encode(Change(favorite: favorite, archived: archived)) else { return }
        do {
            let updated: LAAWorkSession = try await LAAWorkHTTP.write(bridge, path: "/v1/sessions/\(session.id)", body: body,
                                                                     key: LAABridgeIdempotencyKey(), method: "PATCH")
            withAnimation(.snappy) {
                if updated.isArchived != showArchived { sessions.removeAll { $0.id == updated.id } }
                else if let index = sessions.firstIndex(where: { $0.id == updated.id }) { sessions[index] = updated }
            }
            failure = nil
        } catch let error as LAABridgeHTTPError {
            failure = error.status == 404 || error.status == 405 ? "MacのBridgeを更新すると使えます。" : LAAWorkHTTP.message(error)
        } catch {
            failure = "変更を保存できませんでした。"
        }
    }
}

/// Which sessions the Work list starts with: the LAA project (started in
/// /Users/laa) and their children, plus anything the owner pinned. A session
/// from another repo's old worktree does not appear until it is pinned or
/// opened from the archive.
enum LAAWorkSessionScope {
    static func `default`(_ sessions: [LAAWorkSession], projects: [LAAWorkProject]) -> [LAAWorkSession] {
        let laaProjects = Set(projects.filter { $0.name == "LAA" }.map(\.id))
        var keep = Set<String>()
        for session in sessions {
            if session.isFavorite
                || session.cwd == "/Users/laa"
                || session.projectId.map(laaProjects.contains) == true { keep.insert(session.id) }
        }
        var changed = true
        while changed {
            changed = false
            for session in sessions where !keep.contains(session.id) {
                guard let parent = session.parentId, keep.contains(parent) else { continue }
                keep.insert(session.id)
                changed = true
            }
        }
        return sessions.filter { keep.contains($0.id) }
    }
}

/// One session row: status, name, then project · model · time on one line.
struct LAAWorkSessionRow: View {
    let session: LAAWorkSession
    let projectName: String?
    let options: LAAWorkSessionOptions?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x3) {
            Circle().fill(LAAWorkSessionStyle.statusColor(session.phase)).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: LAASpacing.x1) {
                    Text(verbatim: session.name).laaTextStyle(.body).fontWeight(.semibold)
                        .foregroundStyle(LAAColor.text).lineLimit(1)
                        .accessibilityIdentifier("work.session.\(session.id)")
                    if session.isFavorite {
                        Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(LAAColor.secondaryText)
                            .accessibilityLabel(Text(verbatim: "ピン留め"))
                    }
                }
                Text(verbatim: detail).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(1)
            }
            Spacer(minLength: LAASpacing.x2)
            if LAAWorkPresentation.phaseNeedsAttention(session.phase) || session.needsDecision {
                Text(verbatim: session.needsDecision ? "判断待ち" : LAAWorkPresentation.phase(session.phase))
                    .laaTextStyle(.secondary).fontWeight(.semibold).foregroundStyle(LAAColor.attention)
            }
        }
        .padding(.horizontal, LAASpacing.x4)
        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var detail: String {
        [projectName, LAAWorkSessionStyle.model(session, options: options), LAAWorkSessionStyle.relative(session.updatedAt)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

enum LAAWorkSessionOrder {
    /// Favourites first, then the rest; each newest first.
    static func rows(_ sessions: [LAAWorkSession]) -> (pinned: [LAAWorkSession], recent: [LAAWorkSession]) {
        let sorted = sessions.sorted { $0.updatedAt > $1.updatedAt }
        let ids = Set(sessions.map(\.id))
        let roots = sorted.filter { $0.parentId == nil || !ids.contains($0.parentId!) }
        var visited = Set<String>()
        func tree(_ row: LAAWorkSession) -> [LAAWorkSession] {
            guard visited.insert(row.id).inserted else { return [] }
            return [row] + sorted.filter { $0.parentId == row.id }.flatMap(tree)
        }
        var pinned: [LAAWorkSession] = [], recent: [LAAWorkSession] = []
        for root in roots {
            let rows = tree(root)
            if rows.contains(where: \.isFavorite) { pinned += rows } else { recent += rows }
        }
        recent += sorted.filter { !visited.contains($0.id) }
        return (pinned, recent)
    }
    static func depth(_ row: LAAWorkSession, in rows: [LAAWorkSession]) -> Int {
        var parent = row.parentId, depth = 0, seen = Set([row.id])
        while let id = parent, seen.insert(id).inserted, let found = rows.first(where: { $0.id == id }), depth < 4 {
            depth += 1; parent = found.parentId
        }
        return depth
    }
}

enum LAAWorkSessionStyle {
    static func effort(_ raw: String?) -> String? {
        switch raw {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "XHigh"
        case "max": return "Max"
        case let value?: return value
        case nil: return nil
        }
    }

    /// "Opus 5.5 High": Claude's model names stand alone, so its prefix is dropped,
    /// and a trailing build number ("-1017") is left to the detail screen.
    static func shortLabel(_ label: String) -> String {
        let name = label.hasPrefix("Claude ") ? String(label.dropFirst("Claude ".count)) : label
        return name.replacingOccurrences(of: #"-\d{4}$"#, with: "", options: .regularExpression)
    }

    static func profileLabel(_ profile: LAAWorkSessionOptions.Profile, fast: Bool = false) -> String {
        [shortLabel(profile.label), effort(profile.effort)].compactMap { $0 }.joined(separator: " ") + (fast ? " ⚡︎" : "")
    }

    static func model(_ session: LAAWorkSession, options: LAAWorkSessionOptions?) -> String? {
        if let profile = options?.profiles.first(where: { $0.id == session.profile }) {
            return profileLabel(profile, fast: session.fast == true)
        }
        let model = session.observed?.model ?? session.requested?.model
        return model.map { [$0, effort(session.requested?.effort)].compactMap { $0 }.joined(separator: " ") }
    }

    static func statusColor(_ phase: String) -> Color {
        switch phase {
        case "awaiting_decision", "stop_unconfirmed", "error": return LAAColor.attention
        case "running", "created": return LAAColor.link
        default: return LAAColor.separator
        }
    }

    static func relative(_ text: String) -> String? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

enum LAAWorkPaging {
    @MainActor static func all<T: Decodable>(_ bridge: LAABridgeSession, _ path: String,
                                             query: [URLQueryItem] = []) async throws -> [T] {
        var all: [T] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let items = query + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            let page: LAAWorkPage<T> = try await bridge.read(LAAWorkPresentation.path(path, query: items))
            all.append(contentsOf: page.items)
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw LAABridgeError.invalidResponse }
        } while cursor != nil && seen.count < 50
        guard cursor == nil else { throw LAABridgeError.invalidResponse }
        return all
    }
}

struct LAAWorkPrimaryButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text(verbatim: title).fontWeight(.semibold) } icon: { Image(systemName: systemImage) }
                .laaTextStyle(.body)
                .foregroundStyle(LAAColor.filledButtonText)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(LAAColor.filledButton, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct LAAWorkFailure: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: LAASpacing.x2) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
            Text(verbatim: text).laaTextStyle(.secondary).foregroundStyle(LAAColor.text)
            Spacer(minLength: LAASpacing.x2)
            Button { retry() } label: { Text(verbatim: "再試行").laaTextStyle(.secondary).foregroundStyle(LAAColor.link) }
                .buttonStyle(.plain)
        }
        .padding(LAASpacing.x3)
        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
    }
}

/// A row that reveals one action on each side. A full swipe runs it, like Mail.
/// The drag only claims clearly horizontal movement so the page still scrolls.
struct LAAWorkSwipeRow<Content: View>: View {
    struct Action {
        let title: String
        let systemImage: String
        let tint: Color
        let run: () -> Void
    }
    let id: String
    @Binding var openID: String?
    let leading: Action
    let trailing: Action
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var settled: CGFloat = 0
    private let reveal: CGFloat = 88
    private let commit: CGFloat = 170

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                actionButton(leading).frame(width: max(0, offset)).opacity(offset > 0 ? 1 : 0)
                Spacer(minLength: 0)
                actionButton(trailing).frame(width: max(0, -offset)).opacity(offset < 0 ? 1 : 0)
            }
            content()
                .background(LAAColor.surface)
                .offset(x: offset)
        }
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                    if openID != id { openID = id }
                    offset = settled + value.translation.width
                }
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else {
                        withAnimation(.snappy) { offset = settled }
                        return
                    }
                    let final = settled + value.predictedEndTranslation.width
                    if final > commit { finish(leading) }
                    else if final < -commit { finish(trailing) }
                    else {
                        let target: CGFloat = final > reveal / 2 ? reveal : final < -reveal / 2 ? -reveal : 0
                        withAnimation(.snappy) { offset = target }
                        settled = target
                    }
                }
        )
        .onChange(of: openID) { _, value in
            if value != id && offset != 0 { withAnimation(.snappy) { offset = 0 }; settled = 0 }
        }
        .accessibilityAction(named: Text(verbatim: leading.title)) { leading.run() }
        .accessibilityAction(named: Text(verbatim: trailing.title)) { trailing.run() }
    }

    private func actionButton(_ action: Action) -> some View {
        Button { finish(action) } label: {
            VStack(spacing: 2) {
                Image(systemName: action.systemImage).font(.system(size: 16, weight: .semibold))
                Text(verbatim: action.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(action.tint)
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    private func finish(_ action: Action) {
        withAnimation(.snappy) { offset = 0 }
        settled = 0
        action.run()
    }
}
#endif
