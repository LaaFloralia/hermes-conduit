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
    /// Claude Duet's row and page (owner, 2026-11-26). Duet answers in its
    /// own app; the page hands the owner's words over by the owner's tap.
    static let duetRole = "Anthropic"
    static let duetPlaceholder = "Duetに伝えること"
    static let duetOpen = "Duetで開く"
    static let duetOpenHint = "書いた文をコピーしてDuetを開きます。"
    static let duetHowItWorks = "返事・朝の要約・お知らせはDuetのアプリに届きます。書いた文は「Duetで開く」でコピーされるので、Duetの入力欄に貼り付けて送ってください。"
    static let duetCopied = "コピーしました。Duetの入力欄に貼り付けて送ってください。"
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
        static let pokemonCaveat = "メートル表示だけでは証を保証しません。確定はSVのサイズ鑑定です。希少個体を境界値の確認だけのために送らないでください。"
        static let pokemonAudited = "照合済み（GO設定と一致）"
        static let pokemonInferred = "図鑑の高さから計算（GOの基準身長が図鑑と同じ前提・未照合）"
        static let pokemonUnknown = "どのポケモンですか？名前をもう一度入力してください。\n\n\(pokemonCaveat)"
        static let pokemonDataUnavailable = "サイズ表を読み取れません。証の判定は保留します。\n\n\(pokemonCaveat)"
        static func pokemonAmbiguous(_ forms: String) -> String { "どの姿ですか？　\(forms)\n\n\(pokemonCaveat)" }
        static func pokemonUnsupported(_ name: String, tags: LAAChatPokemon.Estimate.TagRanges?) -> String {
            var text = "\(name)はこの姿のままSVの証の判定対象になりません。"
            if let tags { text += "\n\n\(pokemonAudited)\n\n\(pokemonTagRanges(tags))" }
            return text + "\n\n" + pokemonCaveat
        }
        static func pokemonSpecialForm(_ name: String) -> String {
            "\(name)は特殊な姿のため通常の換算は使えません。別の姿の数値では判定しません。\n\n\(pokemonCaveat)"
        }
        static func pokemonSpecialSize(_ name: String) -> String {
            "\(name)はGOで高さの決まりが異なるため、通常の換算は使えません。\n\n\(pokemonCaveat)"
        }
        static func pokemonNoBase(_ name: String) -> String {
            "\(name)の基準身長は未確認のため、数値の目安は出しません。\n\n\(pokemonCaveat)"
        }
        static func pokemonNative(_ name: String) -> String {
            "\(name)：SVで鑑定できる個体なら、Scale 0は「ちっちゃいあかし」、255は「でっかいあかし」です。\n\n\(pokemonCaveat)"
        }
        static func pokemonEstimate(_ name: String, estimate: LAAChatPokemon.Estimate) -> String {
            typealias E = LAAChatPokemon.Estimate
            let source = estimate.tags == nil ? pokemonInferred : pokemonAudited
            var text = """
            \(name)（GO → HOME → SV）

            直接移せる通常個体では、実際のGOの**高さタグ**が **XXS** → ちっちゃいあかし（Scale 0）、**XXL** → でっかいあかし（Scale 255）。複数の実例が一致しています。一部のXS・XLも対象で、重さのタグは別です。

            **表示身長の推定**（基準 \(E.metres(cm: estimate.baseCentimetres)) m）

            \(source)

            - ちっちゃい：\(E.metres(cm: estimate.miniAll)) m以下は丸め幅全体、\(E.metres(cm: estimate.miniPossible)) m は一部のみ該当。
            - でっかい：\(E.metres(cm: estimate.jumboAll)) m以上は丸め幅全体、\(E.metres(cm: estimate.jumboPossible)) m は一部のみ該当。
            """
            if let tags = estimate.tags { text += "\n\n" + pokemonTagRanges(tags) }
            return text + "\n\n" + pokemonCaveat
        }
        private static func pokemonTagRanges(_ tags: LAAChatPokemon.Estimate.TagRanges) -> String {
            typealias E = LAAChatPokemon.Estimate
            return "GOの高さタグの実値範囲：XXS \(E.metres(mm: tags.xxsLow))–\(E.metres(mm: tags.xxsHigh)) m（上端を除く）、XXL \(E.metres(mm: tags.xxlLow))–\(E.metres(mm: tags.xxlHigh)) m。"
        }
        static func pokemonRender(_ answer: String) -> String { "この判定資料だけを改変せず返してください。数値・条件・注意書きは変更しないでください。\n\n\(answer)" }
    }
}
#endif
