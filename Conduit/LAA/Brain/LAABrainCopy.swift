#if LAA_BUILD
import Foundation

extension LAACopy {
    enum Brain {
        static let title = "Doc"
        static let checklist = "Checklist"
        static let bullet = "Bulleted List"
        static let ordered = "Numbered List"
        static let format = "Format"
        static let outdent = "Outdent"
        static let indent = "Indent"
        static let undo = "Undo"
        static let redo = "Redo"
        static let dismissKeyboard = "Hide Keyboard"
        static let subtitle = ""
        static let search = "Search"
        static let recent = "Recent"
        static let folders = "Folder"
        static let tags = "タグ"
        static let tagsUnavailable = "タグを利用できません。"
        static let pinned = "Pinned"
        static let pin = "Pin"
        static let unpin = "Unpin"
        static let links = "Link"
        static let backlinks = "Backlinks"
        static let indexing = "Indexing"
        static let includeInbox = "Include Inbox"
        static let browse = "Browse Folders"
        static let newNote = "新規ノート"
        static let name = "Name"
        static let frontmatter = "Info"
        static let back = "Back"
        static let retry = "Retry"
        static let connect = "Connect to Mac"
        static let chooseFolder = "フォルダを選ぶ"
        static let changeFolder = "Change Destination"
        static let useMac = "Use Mac"
        /// The phone's own folder. On the Mac the same line is about this Mac,
        /// which is why it goes through the device copy.
        static var localFolder: String { LAADeviceCopy.shown("このiPhoneのフォルダ") }
        static let macConnection = "Mac Connection"
        static let settings = "Settings"
        static let cancel = "Cancel"
        static let save = "Save"
        static let checkAgain = "Check Again"
        static let openNote = "Open"
        static let checkInbox = "Check Inbox"
        static let checkPermission = "Check Access"
        static var ownerPermissionRequired: String { AppLocalization.string("Grant this device Brain viewing access on your Mac.") }
    }
}
#endif
