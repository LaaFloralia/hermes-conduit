#if LAA_BUILD
import Foundation

extension LAACopy {
    enum Brain {
        static let title = "Doc"
        static let checklist = "チェックリスト"
        static let bullet = "箇条書き"
        static let ordered = "番号付きリスト"
        static let format = "書式"
        static let outdent = "インデントを戻す"
        static let indent = "インデントを進める"
        static let undo = "取り消す"
        static let redo = "やり直す"
        static let dismissKeyboard = "キーボードを閉じる"
        static let subtitle = ""
        static let search = "検索"
        static let recent = "最近"
        static let folders = "フォルダ"
        static let tags = "タグ"
        static let tagsUnavailable = "タグを利用できません。"
        static let pinned = "ピン留め"
        static let pin = "ピン留めする"
        static let unpin = "ピン留めを外す"
        static let links = "リンク"
        static let backlinks = "このノートへのリンク"
        static let indexing = "ノートを整理中…"
        static let includeInbox = "Inboxを含める"
        static let seeAll = "すべて見る"
        static let showLess = "閉じる"
        static let browse = "フォルダを見る"
        static let newNote = "新規ノート"
        static let name = "名前"
        static let frontmatter = "情報"
        static let back = "戻る"
        static let raw = "Markdownを表示"
        static let formatted = "本文を表示"
        static let retry = "再読み込み"
        static let connect = "Macに接続"
        static let chooseFolder = "フォルダを選ぶ"
        static let changeFolder = "保存先を変更"
        static let useMac = "Mac接続を使う"
        /// The phone's own folder. On the Mac the same line is about this Mac,
        /// which is why it goes through the device copy.
        static var localFolder: String { LAADeviceCopy.shown("このiPhoneのフォルダ") }
        static let macConnection = "Mac接続"
        static let settings = "設定"
        static let close = "閉じる"
        static let cancel = "キャンセル"
        static let save = "保存"
        static let checkAgain = "再確認"
        static let openNote = "ノートを開く"
        static let checkInbox = "Inboxを確認する"
        static let checkPermission = "アクセス権を確認する"
        static var ownerPermissionRequired: String { AppLocalization.string("Grant this device Brain viewing access on your Mac.") }
    }
}
#endif
