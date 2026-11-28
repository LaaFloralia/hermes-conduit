#if LAA_BUILD
import Foundation

// Work-specific navigation and actions live here, alongside the shared copy.
extension LAACopy {
    enum WorkTab {
        static let title = "Work"
        static let subtitle = "Sessions, projects and tasks."
        static let segments = ["Sessions", "Projects", "Tasks"]
        static let sessions = "Sessions"
        static let projects = "Projects"
        static let tasks = "Tasks"
        static let decisions = "Decisions"
        static let skills = "Skills"
        static let project = "Project"
        static let task = "Task"
        static let newSession = "New Session"
        static let newProject = "New Project"
        static let editProject = "Edit Project"
        static let successor = "Follow-up Session"
        static let settings = "Settings"
        static let connect = "Connect to Mac"
        static let retry = "Retry"
        static let reconnect = "Reconnect"
        static let ownerFilter = "Assignee"
        static let statusFilter = "Status"
        static let all = "All"
        static let create = "Create"
        static let cancel = "Cancel"
        static let retryRequest = "Resend"
        static let textSize = "Text Size"
        static let fullEditor = "Expand Composer"
        static let send = "Send"
        /// Send's explicit choice to wait for the running turn (owner 2026-11-15).
        static let sendAfterTurn = "Send After Turn"
        static let checkSuccessor = "Check Follow-up"
        static let resolveSend = "Check Delivery"
        static let confirmSent = "Confirm Sent"
        static let restoreDraft = "Restore Draft"
        static let hold = "Hold"
        static let checkStop = "Check Stop"
        static let retryStop = "Retry Stop"
        static let resume = "Resume"
        static let stop = "Stop"
        static let openSuccessor = "Open Follow-up"
        static let startSuccessor = "Start Follow-up"
        static let resumeNewConversation = "続きは別の会話で開始します。履歴は引き継がれません。"
        static let resumeRemoveImages = "続きの会話を始める前に添付画像を外してください。"
        static let openPendingDecision = "Review Decision"
        static let followUpQueued = "追加指示を送信待ちに入れました。"
        static let followUpDecisionDraft = "追加指示は下書きに残しました。判断後に送信できます。"
        // Follow-ups held on the Mac while the Work engine does not answer.
        // Buttons stay in the app's English title case; status lines are Japanese.
        static let followUpHeldEngineDown = "Workエンジンが応答していません。指示はMacに保持し、復旧後に自動で送ります。"
        static let engineDownDetail = "Workエンジンが応答していません。表示は最後に確認できた状態です。送った指示はMacに保持し、復旧後に自動で送ります。"
        static let engineDownList = "Workエンジンが応答していません。一覧は最後に確認できた状態です。"
        static let modelSwitchChecking = "モデルの引継ぎを確認中です。"
        static let heldEngineDown = "Workエンジンの復旧待ち。復旧後に自動で送ります。"
        static let heldQueued = "順番待ち。今のターンが終わると送ります。"
        static let heldFailed = "送信できませんでした"
        static let heldResend = "Resend"
        static let heldWithdraw = "Withdraw to Draft"
        static let heldWithdrawnCopy = "取り消した指示（下書きが空でないため、ここに残しています）"
        static let unknownFollowUp = "送信結果を確認できませんでした。同じIDで再送しても二重には届きません。"
        static let resendSameID = "Resend Same ID"
        static let log = "Activity Log"
        static let edit = "Edit"
        static let clearLegacy = "Remove Old Reference"
        static let undoClearLegacy = "Keep Reference"
        static let useCurrent = "Use Current"
        static let saveMine = "Save Changes"
        static let compare = "Compare Versions"
        static let save = "Save"
        static let openTask = "Open"
        static let projectName = "Project Name"

        // Keep Work list headings and actions consistent with its menus.
        static let searchSessions = "Search"
        static let newest = "Newest"
        static let byProject = "By Project"
        static let pinned = "Pinned"
        static let recent = "Recent"
        static let archived = "Archived"
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
        static let addRequirement = "Add Requirement"
        static let requirementTitle = "Requirement"
        static let requirementTitlePrompt = "社長の言葉のまま"
        static let requirementDetails = "Details (Optional)"
        static let addFooter = "社長の要件として登録します。題名は後から変えず、補足と状態で進みを表します。"
        static let changeStatus = "Change Status"
        static let withdraw = "Withdraw"
        static func withdrawTitle(_ title: String) -> String { "「\(title)」を取り下げますか？" }
        static let withdrawMessage = "一覧から外します。元の文はMacに残ります。"
        static let addedByAI = "AI-added"
        static let owner = "Owner"
        static let startSession = "New"
        static let startSessionHint = "Start Project Session"
        static let showArchived = "Archived"
        static let hideArchived = "Hide"
        /// Spoken names of the disclosure chevron: the control itself is an icon.
        static let expandHint = "Expand"
        static let collapseHint = "Collapse"
        static let expandedValue = "Expanded"
        static let collapsedValue = "Collapsed"
        static let noRequirements = "要件はまだありません。社長の依頼を、Monetがここへ項目に分けて登録します。"
        static let noRequirementsShort = "No Requirements"
        static let noSessions = "No Sessions"
        static let requirementsUnread = "Macから読み取れた後に表示します。"
        static let unlistedSession = "Unlisted Session"
        static let readMore = "More"
        static let noArchived = "No Archived Sessions"
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
        static let sending = "Sending"

        static func offline(since date: Date?) -> String {
            let when = date.map { LAADateText.string($0, .monthDayTime) } ?? "Unknown"
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

        static func sessionStatus(_ status: LAAWorkStatus) -> String {
            switch status {
            case .decision: "Waiting"
            case .waiting: "Idle"
            case .pending: "Unknown"
            default: status.displayLabel
            }
        }

        static func activity(_ activity: LAAWorkProjectActivity) -> String? {
            switch activity {
            case .idle: nil
            case .running(let count): "\(sessionStatus(.running)) \(count)"
            case .decision(let count): "\(sessionStatus(.decision)) \(count)"
            }
        }
    }
}
#endif
