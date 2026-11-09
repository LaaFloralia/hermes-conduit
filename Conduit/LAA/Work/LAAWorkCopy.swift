#if LAA_BUILD
import Foundation

// Work-specific navigation and actions live here, alongside the shared copy.
extension LAACopy {
    enum WorkTab {
        static let title = "Work"
        static let subtitle = "Sessions, projects and tasks."
        static let segments = ["Sessions", "Projects", "Tasks", "Routines"]
        static let sessions = "Sessions"
        static let project = "Project"
        static let task = "Task"
        static let newSession = "New Session"
        static let newProject = "New Project"
        static let editProject = "Edit Project"
        static let successor = "Successor Session"
        static let settings = "Settings"
        static let connect = "Connect to Mac"
        static let retry = "Retry"
        static let reconnect = "Check Connection"
        static let ownerFilter = "Owner"
        static let statusFilter = "Status"
        static let all = "All"
        static let create = "Create"
        static let close = "Close"
        static let cancel = "Cancel"
        static let retryRequest = "Retry Same Request"
        static let textSize = "Input Text Size"
        static let fullEditor = "Full Screen Editor"
        static let send = "Send"
        static let checkSuccessor = "Check Successor"
        static let resolveSend = "Check Send Status"
        static let confirmSent = "Confirmed Sent"
        static let restoreDraft = "Restore Draft"
        static let hold = "Keep Pending"
        static let checkStop = "Check Stop Status"
        static let retryStop = "Retry Same Stop Request"
        static let resume = "Resume"
        static let stop = "Stop"
        static let openSuccessor = "Open Successor"
        static let log = "Log"
        static let edit = "Edit"
        static let clearLegacy = "Clear Legacy Reference"
        static let undoClearLegacy = "Keep Legacy Reference"
        static let useCurrent = "Use Current Version"
        static let saveMine = "Save My Changes to This Version"
        static let compare = "Compare Current Version"
        static let save = "Save"
        static let openLinear = "Open in Linear"
        static let projectName = "Project Name"

        // One name per action across the Work list, its swipe rows and the
        // context menu. States stay Japanese; actions are short English.
        static let searchSessions = "Search sessions"
        static let pinned = "Pinned"
        static let recent = "Recent"
        static let archived = "Archived"
        static let pin = "Pin"
        static let unpin = "Unpin"
        static let archive = "Archive"
        static let unarchive = "Unarchive"
        static let showArchive = "Show Archive"
        static let backToRecent = "Back to Recent"
    }
}
#endif
