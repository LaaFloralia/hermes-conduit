#if LAA_BUILD
extension LAACopy {
    static let chatsTitle = "Chat"
    static let chatsSearch = "検索"
    static let chatsNew = "新しいグループ"
    static let chatsMonet = "Monet"
    static let chatsEmployees = "Employees"
    /// 派遣社員 (owner, 2026-11-23): Muse and Monet（Dots）.
    static let chatsContractors = "Contractors"
    /// What VoiceOver reads for that heading.
    static let chatsContractorsSpoken = "派遣社員"
    static let chatsGroups = "Groups"
    static let chatsNewGroup = "新しいグループ"
    static let groupDone = "完了"
    static let groupName = "グループ名"
    static let groupNameField = "名前"
    static let groupSelectEmployees = "社員を選択（2〜6人）"
    static let groupCreate = "作成"
    static let groupRename = "名前を変更"
    static let groupRemove = "削除"
    static let groupAddEmployee = "社員を追加"
    static let groupMembers = "メンバー"
    static let groupSettings = "グループの設定"
    static let chatsRetry = "再試行"
    static let chatsCancel = "キャンセル"
    static let chatsNoResults = "一致する項目がありません。"
    static let chatsLoading = "読み込み中…"
    static let chatsOpening = "チャットを開いています…"
    static let chatsOffline = "Macに接続できません。"
    static let chatsIncomplete = "一部を検索できませんでした。"
    static let chatsNoGroups = "グループはまだありません。"
    static let chatsNoEmployees = "社員を読み込めません。"
    static let chatsGroupUnsupported = "この接続先はグループに対応していません。"
    static let chatsUnavailable = "Macに接続すると社員が表示されます。"
    static let chatsNewUnavailable = "今は会話を作れません。Macとの接続を確認してください。"
    static let chatsCron = "Routines"
    static let chatsCronNone = "定期実行はありません。"
    static let chatsCronUnavailable = "定期実行を読み込めません。"
    static let chatsCronStale = "前回の内容を表示しています。"
    static let chatsCronRetry = "再読込"
    static let chatsCronPending = "定期実行を読み込み中…"
    static func chatsCronPartial(_ count: Int) -> String { "一部（\(count)件）を読み込めませんでした。" }
    static let chatsCronToChat = "このチャットに届く"
    static let chatsCronRecordOnly = "実行記録のみ（会話に残る）"
    static let chatsCronRuns = "最近の実行"
    static func chatsUnread(_ count: Int) -> String { "未読\(count)件" }

    enum ChatProjects {
        static let title = "Projects"
        static let new = "New"
        static let edit = "Edit"
        static let save = "Save"
        static let done = "Done"
        static let running = "Running"
        static let delete = "削除"
        static let deleteTitle = "プロジェクトを削除しますか？"
        static let deleteHistory = "この端末の会話履歴と前提知識も削除します。"
        static let name = "名前"
        static let context = "前提知識（Markdown）"
        static let model = "Model"
        static let question = "質問を入力"
        static let everyday = "日常質問"
        static let pokemon = "ポケモンサイズ証判定"
        static let empty = "プロジェクトはまだありません。"
        static let storageError = "プロジェクトを保存できません。端末の空き容量を確認してください。"
        static let storageReadError = "プロジェクトの保存内容を読み取れません。元のデータは変更していません。"
        static let check = "送信結果を確認"
        static let keepDraft = "下書きに戻す"
        static let unknownDelivery = "送信結果は未確認です。自動では再送しません。"
        static let longInput = "質問と前提知識を短くしてから送信してください。"
        static func unavailable(_ model: String) -> String { "\(model) は現在利用できません。別のモデルには切り替えません。" }
        static func quota(_ model: String, at: String) -> String { "\(model) の利用枠を使い切りました。再開予定：\(at)" }
        static let pokemonContext = """
        route: go-home-sv

        GOからHOMEを経由し、SVのサイズ鑑定を前提にする。メートル表示だけでは証を保証しない。
        SVでの判定だけに切り替えるには、先頭行を `route: sv-native` に変更。
        """
        static let pokemonUnknown = "どのポケモンですか？名前をもう一度入力してください。"
        static let pokemonDataUnavailable = "サイズ表を読み取れません。証の判定は保留します。"
        static func pokemonAmbiguous(_ forms: String) -> String { "どの姿ですか？　\(forms)" }
        static func pokemonUnsupported(_ name: String) -> String { "\(name) はこの姿のままSVの証の判定対象になりません。" }
        static func pokemonUnaudited(_ name: String) -> String { "\(name) のGOからSVへの参考値は未確認です。メートル表示だけでは証は確定せず、対応する個体はSVのサイズ鑑定で確認できます。" }
        static func pokemonNative(_ name: String) -> String { "\(name)：SVで鑑定できる個体なら、Scale 0は「ちっちゃいあかし」、255は「でっかいあかし」です。名前やメートル表示だけでは確定せず、SVのサイズ鑑定で確認します。" }
        static func pokemonEstimate(_ name: String, mini: String, jumbo: String) -> String {
            "\(name)（GO → HOME → SV）\n\nちっちゃいあかし：\(mini) m 以下が目安（Scale 0）\nでっかいあかし：\(jumbo) m 以上が目安（Scale 255）\n\n境界は推定です。メートル表示だけでは証を保証しません。GOの高さのXXS・XXLは有力な目安で、対応する個体はSVのサイズ鑑定で確定します。"
        }
        static func pokemonRender(_ answer: String) -> String { "この照合結果だけを改変せず返してください。数値・条件・注意書きは変更しないでください。\n\n\(answer)" }
    }
}
#endif
