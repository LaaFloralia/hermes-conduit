#if LAA_BUILD && DEBUG
import SwiftUI

/// Work's project screens with synthetic data, for screenshots and the
/// 440 × 956 snapshot tests. It draws the production list row and detail
/// page; no Bridge is read and no change is sent.
///
///   -LAA_WORK_PROJECT_FIXTURE <state>
///
/// States: `list` (the phone's project list), `detail` (requirements in
/// every state), `empty` (a project without requirements), `loading`,
/// `error`, `offline` (the copy kept on the device), `legacy` (a Bridge
/// without requirements), `done` (every requirement completed) and `many`
/// (the default project: no requirements, the first 200 of many sessions and
/// a large archive, like the owner's 「未分類」). On the Mac
/// every state draws the list beside its detail.
struct LAAWorkProjectFixtureView: View {
    static let launchArgument = "-LAA_WORK_PROJECT_FIXTURE"

    enum Mode: String, CaseIterable {
        case list, detail, empty, loading, error, offline, legacy, done, many
    }

    let state: Mode
    @Environment(\.laaDesktop) private var laaDesktop

    init(state: Mode? = nil) {
        if let state { self.state = state; return }
        let arguments = ProcessInfo.processInfo.arguments
        let raw = arguments.firstIndex(of: Self.launchArgument).flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        self.state = raw.flatMap(Mode.init(rawValue:)) ?? .detail
    }

    var body: some View {
        #if targetEnvironment(macCatalyst)
        desktop
            .environment(\.laaDesktop, true)
            .frame(minWidth: LAAMacWindow.minimumWidth, minHeight: LAAMacWindow.minimumHeight)
            .background(LAAColor.background.ignoresSafeArea())
            .background(LAAMacWindowConstraints())
        #else
        phone
        #endif
    }

    // MARK: Screens

    @ViewBuilder private var phone: some View {
        NavigationStack {
            if state == .list { phoneList } else { detailScreen }
        }
        .tint(LAAColor.link)
    }

    private var phoneList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                LAAWorkPrimaryButton(title: "新しいプロジェクト", systemImage: "plus") {}
                VStack(spacing: 0) {
                    ForEach(Self.projects) { project in
                        LAAWorkProjectRow(project: project, activity: Self.activity(project.id))
                        if project.id != Self.projects.last?.id {
                            Divider().overlay(LAAColor.separator).padding(.leading, LAASpacing.x4)
                        }
                    }
                }
                .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous))
            }
            .padding(LAASpacing.horizontal)
        }
        .background(LAAColor.background.ignoresSafeArea())
        .navigationTitle(Text(verbatim: "プロジェクト"))
        .accessibilityIdentifier("laa.work.project.fixture.list")
    }

    private var detailScreen: some View {
        ScrollView {
            LAAWorkProjectPage(project: project, detail: detail, sessions: sessions, options: Self.options, phase: phase,
                               moreSessions: state == .many)
                .padding(.horizontal, LAASpacing.horizontal).padding(.vertical, LAASpacing.x4)
                .frame(maxWidth: laaDesktop ? LAADesktopMetrics.documentWidth : 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: laaDesktop ? .center : .leading)
        }
        .background(LAAColor.background.ignoresSafeArea())
        .navigationTitle(Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("laa.work.project.fixture.\(state.rawValue)")
    }

    #if targetEnvironment(macCatalyst)
    private var desktop: some View {
        LAAMacListDetail {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Self.projects) { row in
                        LAAWorkProjectRow(project: row, activity: Self.activity(row.id))
                            .background(row.id == project.id ? LAAColor.selectionFill : .clear,
                                        in: RoundedRectangle(cornerRadius: LAARadius.card))
                    }
                }
                .padding(.vertical, LAASpacing.x3)
            }
        } detail: {
            NavigationStack { detailScreen }
        }
    }
    #endif

    // MARK: Data

    private var phase: LAAWorkProjectPhase {
        switch state {
        case .loading: .loading
        case .error: .failed("Macからの応答を読み取れませんでした。")
        case .offline: .offline(Self.date("2026-11-23T05:42:00Z"))
        default: .ready
        }
    }

    private var project: LAAWorkProject {
        switch state {
        case .empty: Self.projects[3]
        case .done: Self.projects[2]
        case .many: Self.uncategorized
        default: Self.projects[0]
        }
    }

    private var detail: LAAWorkProjectSnapshot? {
        switch state {
        case .loading: nil
        case .error: nil
        case .legacy: LAAWorkProjectSnapshot(progressNote: nil, requirements: nil, sessions: nil, savedAt: Date())
        default: LAAWorkProjectSnapshot(project, at: Self.date("2026-11-23T05:42:00Z") ?? Date())
        }
    }

    private var sessions: [LAAWorkSession] {
        switch state {
        case .loading, .error, .empty: []
        case .done: [Self.session("ses_00000000000000d1", ref: "S21", name: "LAAアプリ｜週報の下書き", phase: "awaiting_review",
                                  model: "claude-opus-5-5", effort: "high", updated: "2026-11-21T03:00:00Z")]
        case .many: Self.manySessions
        default: Self.appSessions
        }
    }

    private static func activity(_ id: String) -> LAAWorkProjectActivity {
        switch id {
        case "prj_00000000000a": .decision(1)
        case "prj_00000000000b": .running(1)
        default: .idle
        }
    }

    /// The model names the session rows show, as `/v1/session-options` gives them.
    static let options = LAAWorkSessionOptions(profiles: [
        .init(id: "opus-high", label: "Claude Opus 5.5", provider: "claude", model: "claude-opus-5-5", effort: "high", fast: false),
        .init(id: "sol-high", label: "GPT-6 Sol", provider: "codex", model: "gpt-6-sol", effort: "high", fast: false),
        .init(id: "terra-high", label: "GPT-6 Terra", provider: "codex", model: "gpt-6-terra", effort: "high", fast: false),
        .init(id: "dsh-high", label: "DeepSeek V4.1 Flash", provider: "dsh", model: "deepseek-v4.1-flash", effort: "high", fast: false),
    ], defaultProfile: "opus-high", defaultMode: "bypass")

    static let requirements: [LAAWorkRequirement] = [
        .init(id: "req_000000000001", title: "プロジェクトを開いたら、要件の完了と着手中が一目で分かる",
              details: "Session一覧に加えて、社長の要件とAIが足した項目の状態を一覧で出す。",
              status: .inProgress, sessionIds: ["ses_00000000000000a1"], order: 0),
        .init(id: "req_000000000002", title: "Sessionは必ずプロジェクトの中に作る", status: .completed,
              sessionIds: ["ses_00000000000000a2"], order: 1),
        .init(id: "req_000000000003", title: "Macの一覧も5秒ごとに読み直す", details: "iPhoneと同じ間隔。画面を開いている間だけ。",
              source: "ai", status: .inProgress, sessionIds: ["ses_00000000000000a3", "ses_00000000000000a4"], order: 2),
        .init(id: "req_000000000004", title: "未分類のプロジェクトの名前を決める",
              details: "「未分類」のままにするか、「その他」にするか。", status: .awaitingDecision,
              sessionIds: ["ses_00000000000000a5"], order: 3),
        .init(id: "req_000000000005", title: "TestFlightへ出してiPhoneで確かめる", status: .notStarted, order: 4),
        .init(id: "req_000000000006", title: "旧データのSessionを既定のプロジェクトへ入れる", source: "ai", status: .completed, order: 5),
        .init(id: "req_000000000007", title: "Monetの道具からプロジェクトを作れるようにする", status: .completed, order: 6),
    ]

    static let compactSessions: [LAAWorkProjectSession] = [
        .init(id: "ses_00000000000000a1", name: "LAAアプリ｜プロジェクト画面", status: "running", model: "claude-opus-5-5",
              updatedAt: "2026-11-23T05:40:00Z", parentId: nil, archivedAt: nil),
        .init(id: "ses_00000000000000a2", name: "LAAアプリ｜Sessionの所属", status: "completed", model: "gpt-6-sol",
              updatedAt: "2026-11-23T03:10:00Z", parentId: nil, archivedAt: nil),
        .init(id: "ses_00000000000000a3", name: "子｜Macの定期読込み", status: "running", model: "deepseek-v4.1-flash",
              updatedAt: "2026-11-23T05:38:00Z", parentId: "ses_00000000000000a1", archivedAt: nil),
        .init(id: "ses_00000000000000a4", name: "子｜iPhoneの読込み試験", status: "waiting", model: "deepseek-v4.1-flash",
              updatedAt: "2026-11-23T05:20:00Z", parentId: "ses_00000000000000a1", archivedAt: nil),
        .init(id: "ses_00000000000000a5", name: "LAAアプリ｜Bridgeの既定プロジェクト", status: "awaiting_decision", model: "gpt-6-terra",
              updatedAt: "2026-11-23T05:05:00Z", parentId: nil, archivedAt: nil),
        .init(id: "ses_00000000000000a6", name: "LAAアプリ｜前回の調査", status: "completed", model: "claude-opus-5-5",
              updatedAt: "2026-11-20T05:05:00Z", parentId: nil, archivedAt: "2026-11-21T00:00:00Z"),
    ]

    static let appSessions: [LAAWorkSession] = [
        session("ses_00000000000000a1", ref: "S41", name: "LAAアプリ｜プロジェクト画面", phase: "running",
                model: "claude-opus-5-5", effort: "high", updated: "2026-11-23T05:40:00Z"),
        session("ses_00000000000000a3", ref: "S43", name: "子｜Macの定期読込み", phase: "running",
                model: "deepseek-v4.1-flash", effort: "high", updated: "2026-11-23T05:38:00Z", parent: "ses_00000000000000a1"),
        session("ses_00000000000000a4", ref: "S44", name: "子｜iPhoneの読込み試験", phase: "awaiting_review",
                model: "deepseek-v4.1-flash", effort: "high", updated: "2026-11-23T05:20:00Z", parent: "ses_00000000000000a1"),
        session("ses_00000000000000a5", ref: "S45", name: "LAAアプリ｜Bridgeの既定プロジェクト", phase: "awaiting_decision",
                model: "gpt-6-terra", effort: "high", updated: "2026-11-23T05:05:00Z"),
        session("ses_00000000000000a2", ref: "S42", name: "LAAアプリ｜Sessionの所属", phase: "closed",
                model: "gpt-6-sol", effort: "high", updated: "2026-11-23T03:10:00Z"),
    ]

    static let projects: [LAAWorkProject] = [
        LAAWorkProject(id: "prj_00000000000a", name: "LAAアプリ", ref: "P2", etag: "\"fixture-1\"",
                       updatedAt: "2026-11-23T05:40:00Z",
                       instructions: "公開repo。秘密と非公開の識別子を入れない。xcodebuildは共有の枠で1本ずつ。",
                       files: [LAAWorkProjectFile(id: "file_1", name: "画面の参考.pdf", size: 482_000, mimeType: "application/pdf", createdAt: nil)],
                       requirementSummary: .init(completed: 3, total: 7),
                       progressNote: "要件の一覧とMacの定期読込みを実装中。次はBridgeの既定プロジェクト名を社長に確認してから、TestFlightへ出す。",
                       requirements: requirements, sessions: compactSessions,
                       sessionCounts: .init(active: 5, archived: 1)),
        LAAWorkProject(id: "prj_00000000000b", name: "法人化", ref: "P5", updatedAt: "2026-11-22T09:00:00Z",
                       requirementSummary: .init(completed: 1, total: 4),
                       progressNote: "会社形態の比較表を作成中。"),
        LAAWorkProject(id: "prj_00000000000c", name: "週報", ref: "P7", etag: "\"fixture-3\"", updatedAt: "2026-11-21T03:00:00Z",
                       requirementSummary: .init(completed: 2, total: 2),
                       progressNote: "今週分は提出済み。",
                       requirements: [
                           .init(id: "req_000000000011", title: "今週の週報を下書きする", status: .completed,
                                 sessionIds: ["ses_00000000000000d1"], order: 0),
                           .init(id: "req_000000000012", title: "提出前に数字を確かめる", source: "ai", status: .completed, order: 1),
                       ],
                       sessions: [.init(id: "ses_00000000000000d1", name: "LAAアプリ｜週報の下書き", status: "waiting",
                                        model: "claude-opus-5-5", updatedAt: "2026-11-21T03:00:00Z", parentId: nil, archivedAt: nil)]),
        LAAWorkProject(id: "prj_00000000000d", name: "PR動画", ref: "P9", etag: "\"fixture-4\"", updatedAt: "2026-11-19T03:00:00Z",
                       requirementSummary: .init(completed: 0, total: 0), requirements: [], sessions: []),
        LAAWorkProject(id: "prj_000000000000", name: "未分類", ref: "P1", updatedAt: "2026-11-18T03:00:00Z"),
    ]

    /// The default project as the Bridge shows it to an owner with a long
    /// history: no requirements, 230 open sessions (200 on the first page)
    /// and 1,584 archived ones.
    static let uncategorized = LAAWorkProject(
        id: "prj_000000000000", name: "未分類", ref: "P1", etag: "\"fixture-5\"", updatedAt: "2026-11-23T05:40:00Z",
        requirementSummary: .init(completed: 0, total: 0), requirements: [],
        sessions: manySessions.map { .init(id: $0.id, name: $0.name, status: "waiting", model: nil, updatedAt: nil,
                                           parentId: nil, archivedAt: nil) },
        sessionCounts: .init(active: 230, archived: 1584))

    static let manySessions: [LAAWorkSession] = (0..<200).map { index in
        let minutes = String(format: "%02d", 59 - index % 60)
        let hour = String(format: "%02d", 23 - index / 60)
        return session(String(format: "ses_%016x", 0xb000 + index), ref: "S\(900 + index)",
                       name: "未分類｜作業 \(200 - index)", phase: index % 17 == 0 ? "running" : "awaiting_review",
                       model: index % 3 == 0 ? "gpt-6-sol" : "claude-opus-5-5", effort: "high",
                       updated: "2026-11-22T\(hour):\(minutes):00Z")
    }

    static func date(_ value: String) -> Date? { LAAWorkFreshness.date(value) }

    /// A Bridge session row, decoded the way the app decodes the Bridge's.
    static func session(_ id: String, ref: String, name: String, phase: String, model: String, effort: String,
                        updated: String, parent: String? = nil) -> LAAWorkSession {
        let provider = model.hasPrefix("claude") ? "claude" : model.hasPrefix("gpt") ? "codex" : "dsh"
        let row: [String: Any] = [
            "id": id, "ref": ref, "name": name, "nameSource": "agent", "requestId": id,
            "parentId": parent ?? NSNull(), "projectId": "prj_00000000000a", "workspaceId": "ws_fixture", "cwd": "/tmp/fixture",
            "profile": "fixture", "phase": phase,
            "requested": ["provider": provider, "model": model, "effort": effort],
            "observed": ["provider": provider, "model": model, "effort": effort],
            "pending": phase == "awaiting_decision" ? ["count": 1, "kinds": ["question"]] as Any : NSNull(),
            "createdAt": updated, "updatedAt": updated,
            "events": ["lastSeq": 1, "oldestSeq": 1, "cursor": "fixture"],
        ]
        let data = try! JSONSerialization.data(withJSONObject: row)
        return try! JSONDecoder().decode(LAAWorkSession.self, from: data)
    }
}
#endif
