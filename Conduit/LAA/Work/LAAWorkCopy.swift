#if LAA_BUILD
import Foundation

// Work-specific navigation and actions live here, alongside the shared copy.
extension LAACopy {
    enum WorkTab {
        static let title = "Work"
        static let subtitle = "Sessions, projects and tasks."
        static let segments = ["Sessions", "Projects", "Tasks", "Routines"]
        static let sessions = "Sessions"
        static let projects = "Projects"
        static let tasks = "Tasks"
        static let routines = "Routines"
        static let decisions = "Decisions"
        static let skills = "Skills"
        static let project = "Project"
        static let task = "Task"
        static let newSession = "新しいセッション"
        static let newProject = "新しいプロジェクト"
        static let editProject = "プロジェクトを編集"
        static let successor = "続きのセッション"
        static let settings = "Settings"
        static let connect = "Macに接続"
        static let retry = "Retry"
        static let reconnect = "接続し直す"
        static let ownerFilter = "担当"
        static let statusFilter = "状態"
        static let all = "すべて"
        static let create = "作成"
        static let close = "Close"
        static let cancel = "Cancel"
        static let retryRequest = "もう一度送る"
        static let textSize = "文字サイズ"
        static let fullEditor = "入力欄を広げる"
        static let send = "Send"
        /// Send's explicit choice to wait for the running turn (owner 2026-11-15).
        static let sendAfterTurn = "この手番の後に送る"
        static let checkSuccessor = "続きのセッションを確認"
        static let resolveSend = "送信状況を確認"
        static let confirmSent = "送信済みを確認"
        static let restoreDraft = "下書きに戻す"
        static let hold = "保留する"
        static let checkStop = "中断状況を確認"
        static let retryStop = "もう一度中断を要求"
        static let resume = "再開"
        static let stop = "中断"
        static let openSuccessor = "続きを開く"
        static let startSuccessor = "続きの会話を開始"
        static let resumeNewConversation = "続きは別の会話で開始します。履歴は引き継がれません。"
        static let resumeRemoveImages = "続きの会話を始める前に添付画像を外してください。"
        static let openPendingDecision = "判断を確認"
        static let followUpQueued = "追加指示を送信待ちに入れました。"
        static let followUpDecisionDraft = "追加指示は下書きに残しました。判断後に送信できます。"
        static let log = "作業の記録"
        static let edit = "Edit"
        static let clearLegacy = "古い参照を外す"
        static let undoClearLegacy = "参照を残す"
        static let useCurrent = "現在の内容を使う"
        static let saveMine = "変更を保存"
        static let compare = "現在の内容と比較"
        static let save = "Save"
        static let openLinear = "Linearで開く"
        static let projectName = "プロジェクト名"

        // One name per action across the Work list, its swipe rows and the
        // context menu. States stay Japanese; actions are short English.
        static let searchSessions = "検索"
        static let pinned = "ピン留め"
        static let recent = "最近"
        static let archived = "アーカイブ"
        static let pin = "Pin"
        static let unpin = "Unpin"
        static let archive = "Archive"
        static let unarchive = "Restore"
        static let showArchive = "Archived"
        static let backToRecent = "Recent"
    }

    /// A project's detail: its requirements, Monet's note and its sessions.
    /// Status names are short English words; the requirements stay Japanese
    /// (DESIGN 「日本語と英語」, owner 2026-11-26).
    enum WorkProject {
        static let requirements = "Requirements"
        static let instructions = "Instructions"
        static let files = "Files"
        static let note = "Note"
        static let add = "Add"
        static let addRequirement = "要件を追加"
        static let requirementTitle = "要件"
        static let requirementTitlePrompt = "社長の言葉のまま"
        static let requirementDetails = "補足（任意）"
        static let addFooter = "社長の要件として登録します。題名は後から変えず、補足と状態で進みを表します。"
        static let changeStatus = "状態を変える"
        static let withdraw = "取り下げる"
        static func withdrawTitle(_ title: String) -> String { "「\(title)」を取り下げますか？" }
        static let withdrawMessage = "一覧から外します。元の文はMacに残ります。"
        static let addedByAI = "AI追加"
        static let addedByAIHint = "AIが足した項目"
        static let ownerHint = "社長の要件"
        static let startSession = "New"
        static let startSessionHint = "このプロジェクトで新しいセッションを開始"
        static let showArchived = "Archived"
        static let hideArchived = "Hide"
        /// Spoken names of the disclosure chevron: the control itself is an icon.
        static let expandHint = "Expand"
        static let collapseHint = "Collapse"
        static let expandedValue = "Expanded"
        static let collapsedValue = "Collapsed"
        static let noRequirements = "要件はまだありません。社長の依頼を、Monetがここへ項目に分けて登録します。"
        static let noRequirementsShort = "要件なし"
        static let noSessions = "まだありません。"
        static let requirementsUnread = "Macから読み取れた後に表示します。"
        static let unlistedSession = "一覧にないセッション"
        static let readMore = "More"
        static let noArchived = "アーカイブしたセッションはありません。"
        static func archivedCount(_ count: Int) -> String { "Archived \(count)" }
        static let bridgeTooOld = "MacのLAAアプリを更新すると、要件の一覧と進捗を表示できます。"
        static let conflict = "別の端末で更新されていました。読み直したので、もう一度操作してください。"
        static let limitReached = "このプロジェクトの要件は上限に達しています。"
        static let archivedProject = "アーカイブしたプロジェクトの要件は変更できません。"
        static let saveFailed = "変更を保存できませんでした。"
        static let readFailed = "プロジェクトを読み取れませんでした。"
        static let instructionsEmpty = "このプロジェクトの全セッションに渡す指示を書けます。"
        static let filesEmpty = "PDF・画像・メモなどを追加すると、セッションが必要な時に読みます。"
        static let fileHint = "長押しで削除できます。"
        static let details = "Details"
        static let linkedSessions = "Sessions"
        static func updated(_ text: String) -> String { "Updated \(text)" }
        static let edit = "Edit"
        static let sending = "送信中"

        static func offline(since date: Date?) -> String {
            let when = date.map { LAADateText.string($0, .monthDayTime) } ?? "未確認"
            return "Macに届きません。\(when)に取得した内容です。"
        }
        static func done(_ completed: Int, of total: Int) -> String { "Done \(completed) / \(total)" }
        static func progressLabel(_ completed: Int, of total: Int) -> String { "要件 \(total)件中 \(completed)件完了" }

        static func status(_ status: LAAWorkRequirementStatus) -> String {
            switch status {
            case .inProgress: "In progress"
            case .awaitingDecision: "Decision"
            case .notStarted: "Not started"
            case .completed: "Done"
            case .unknown: "Unknown"
            }
        }

        static func sessionStatus(_ raw: String) -> String {
            switch raw {
            case "running": "実行中"
            case "waiting": "待機"
            case "awaiting_decision": "判断待ち"
            case "completed": "完了"
            default: "状態不明"
            }
        }

        static func activity(_ activity: LAAWorkProjectActivity) -> String? {
            switch activity {
            case .idle: nil
            case .running(let count): "実行中のセッション \(count)件"
            case .decision(let count): "判断待ちのセッション \(count)件"
            }
        }
    }
}
#endif
