#if LAA_BUILD
extension LAACopy {
    static let serverUnavailableTitle = "利用できません"
    static let serverFeatureUnavailable = "この機能はこのMacでは利用できません"

    /// What this Mac cannot do yet, in one sentence: the feature, not the
    /// cause and not a retry that would not help. Eighteen call sites shared
    /// one wording, so it is written once here.
    static func notAvailable(_ feature: String) -> String {
        "このMacでは\(feature)を利用できません"
    }

    static let artifactsUnavailable = notAvailable("成果物の一覧")
    static let workspaceActionsUnavailable = notAvailable("フォルダ内の検索とファイルの作成・移動・削除")
    static let groupFilesUnavailable = notAvailable("グループへのファイル送信")
    static let gptLiveUnavailable = notAvailable("GPT-Live")
    static let gptLiveAPIUnavailable = notAvailable("GPT-LiveのAPIキー通話")
    static let employeePersonalityUnavailable = "社員の人格を読み込めません"
    static let phoneSharingUnavailable = notAvailable("カレンダーと端末の状態の共有")
    static let healthSharingUnavailable = notAvailable("ヘルスケアの共有")
    static let locationSharingUnavailable = notAvailable("位置情報の共有")
    static let syncedPreferencesUnavailable = notAvailable("設定の端末間同期")
    static let predictiveUnavailable = notAvailable("予測機能")
    static let speechServerUnavailable = notAvailable("音声サーバー")
    static let fastModelUnavailable = notAvailable("高速モデル")
    static let localLiveUnavailable = notAvailable("Local Live")
    static let voiceHistoryUnavailable = notAvailable("通話の保存") + "。通話はこの端末に保持されています。"
    static let shortcutInboxUnavailable = notAvailable("記録の表示と削除")
    static let shortcutEventKept = notAvailable("記録") + "。このイベントは端末に保持されています。"
    static let shortcutEventNotKept = notAvailable("記録") + "。このイベントは保持されていません。"
    static let unreadableServerResponse = "Macの応答を読み取れません"
    static let unscopedNotificationUnavailable = "この通知には送信元の情報が含まれていないため、このMacではまだ開けません。"
    static let watchVoiceStatusUnavailable = "WatchのGPT-Liveの状態を確認できませんでした。"
    static let watchCallUnavailable = "Watchの音声通話を開始できませんでした。Macとの接続を確認してください。"
    static let voiceSetupManaged = "音声接続はMac側で管理されています。"
    static let voiceNotConfirmed = "Macが選択した声を確認できませんでした。"
    static let otherCallInProgress = "別の通話を終了してください"
    static let dictationDuringCallHint = "話した内容を入力します。\(otherCallInProgress)"
    static let sharingPausedPrefix = "一時停止中。"
}
#endif
