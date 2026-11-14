#if LAA_BUILD

import Foundation

enum LAACopy {
    // MARK: Tabs

    /// The tab and navigation titles, in the order the bar shows them.
    static func tabTitle(_ tab: LAATab) -> String {
        switch tab {
        case .chats: return "Chat"
        case .today: return "Today"
        case .studio: return "Studio"
        case .work: return "Work"
        case .brain: return "Doc"
        case .source: return "Assets"
        case .usage: return "Usage"
        }
    }

    // MARK: Shared controls

    static let instructionFiles = "指示ファイル"
    static let instructionFileNames = "AGENTS.md / CLAUDE.md"
    static let brand = "LAA"
    static let agent = "Monet"
    static let settings = "Settings"
    /// The Today tab's fourth segment. English like the tab names; not an upstream catalog key.
    static let habitsMode = "Habits"
    static let loginMacAddress = "Macのアドレス"
    static let loginMacSubtitle = "Macに接続します"
    static let plugin = "接続の状態"
    static let pairingTitle = "Macに接続"
    static let pairingAddress = "アドレス"
    static let pairingCode = "接続コード"
    static let pairingConnect = "接続"
    static let mac = "Mac"
    static let macRePair = "接続し直す"
    static let macRefresh = "再試行"
    static let macChecking = "接続中"
    static let macConnected = "接続済み"
    static let macOffline = "未接続"
    static let macNotPaired = "未接続"
    static let macRePairRequired = "未接続"
    static let macKeychainError = "認証情報を読み取れません"
    static let macConnectionError = "接続できません"
    static let macConnectingBody = "Macに接続中…"
    static let macVoiceSettingsUnavailable = "音声設定を取得できません"
    static let callsFromMonet = "着信"
    static let callsFromMonetDetail = "着信を受ける条件"
    static let screenQuestionAddShortcut = "ショートカットを追加"
    static let dataAndLicenses = "データとライセンス"
    static let dataAndLicensesDetail = "端末のデータとライセンス"
    static let openSourceLicenses = "オープンソースライセンス"
    static let back = "戻る"
    static let close = "閉じる"
    static let cancel = "キャンセル"
    static let save = "保存"
    static let done = "完了"
    static let call = "電話"
    static let callMute = "消音"
    static let callUnmute = "消音を解除"
    static let callSpeaker = "スピーカー"
    static let callChat = "チャット"
    static let callEnd = "終了"
    static let callAudioRoute = "音声の出力先"
    static let callReceiver = "受話口"
    static let callNoOutput = "出力先なし"
    static let callReturn = "通話に戻る"
    static let pluginVersion = "バージョン"
    static let pluginDashboard = "Mac"
    static let pluginConnection = "接続"
    static let pluginConnected = "接続済み"
    static let pluginNotConnected = "未接続"
    static let pluginUnavailable = "利用できません"
    static let pluginChecking = "接続中"
    static let pluginNotChecked = "未確認"
    static let pluginNotificationsUnavailable = "このMacでは通知を利用できません"
    static let pluginCardsUnavailable = "このAI社員は確認カードに対応していません"
    static let pluginEncryptionUnavailable = "暗号化されていないため、通知の本文と会話への移動は利用できません"
    static let pluginRotationUnavailable = "通知はこのiPhoneだけで読める暗号化で保護されます。暗号鍵の自動更新は利用できません。"
    static let loading = "読み込み中"
    static let notFetched = "未取得"
    static let needsAttention = "要確認"
    static let refreshedAt = "更新時刻"
    static let notConnected = "未接続"
    static let noItems = "0件"
    static let never = "—"

    // MARK: Bridge

    static let bridgeNotPairedBody = "Macに接続してください"

    // MARK: iPhone Use (Live Activity)

    static let phoneUseAsk = "iPhoneを操作してよいですか"
    static let phoneUseOperating = "iPhoneを操作中"
    static let phoneUseAllow = "許可"
    static let phoneUseDeny = "許可しない"
    static let phoneUseStop = "停止"
    static let phoneUseOperatingShort = "操作中"

    #if os(iOS) && !targetEnvironment(macCatalyst)
    static func phoneUseFinished(_ phase: LAAPhoneUsePhase) -> String {
        switch phase {
        case .denied: return "許可しませんでした"
        case .stopped: return "操作を止めました"
        case .expired: return "時間切れのため操作しません"
        case .ended, .ask, .operating: return "操作を終えました"
        }
    }
    #endif
}

#endif
