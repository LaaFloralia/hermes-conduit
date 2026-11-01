#if LAA_BUILD

import Foundation

enum LAACopy {
    // MARK: Tabs

    /// The tab and navigation titles, in the order the bar shows them.
    static func tabTitle(_ tab: LAATab) -> String {
        switch tab {
        case .chats: return "Chats"
        case .work: return "Work"
        case .brain: return "Brain"
        case .source: return "Assets"
        case .usage: return "Usage"
        }
    }

    // MARK: Shared controls

    static let brand = "LAA"
    static let agent = "Ciel"
    static let settings = "Settings"
    static let loginMacAddress = "Mac address"
    static let loginMacSubtitle = "Connect to your Mac"
    static let plugin = "Connection status"
    static let pairingTitle = "Connect to Mac"
    static let pairingAddress = "Address"
    static let pairingCode = "Pairing code"
    static let pairingConnect = "Connect"
    static let mac = "Mac"
    static let macRePair = "Re-pair"
    static let macRefresh = "Refresh"
    static let macChecking = "Checking…"
    static let macConnected = "Connected"
    static let macOffline = "Offline"
    static let macNotPaired = "Not paired"
    static let macRePairRequired = "Re-pair required"
    static let macKeychainError = "Keychain error"
    static let macConnectionError = "Connection error"
    static let macConnectingBody = "Macに接続しています。しばらくしてからもう一度お試しください。"
    static let macVoiceSettingsUnavailable = "Macの音声設定を取得できません。テキストの会話は引き続き使えます。"
    static let callsFromCiel = "Calls from Ciel"
    static let callsFromCielDetail = "When Ciel may call you"
    static let screenQuestionAddShortcut = "Add shortcut"
    static let dataAndLicenses = "Data & licenses"
    static let dataAndLicensesDetail = "Device data and open-source licenses"
    static let openSourceLicenses = "Open-source licenses"
    static let close = "Close"
    static let done = "Done"
    static let call = "Call"
    static let callMute = "Mute"
    static let callUnmute = "Unmute"
    static let callSpeaker = "Speaker"
    static let callChat = "Chat"
    static let callEnd = "End"
    static let callAudioRoute = "Audio output"
    static let callReceiver = "Receiver"
    static let callNoOutput = "No output"
    static let callReturn = "Return to call"
    static let pluginVersion = "Version"
    static let pluginDashboard = "Dashboard"
    static let pluginConnection = "Connection"
    static let pluginConnected = "Connected"
    static let pluginNotConnected = "Not connected"
    static let pluginUnavailable = "Unavailable"
    static let pluginChecking = "Checking…"
    static let pluginNotChecked = "Not checked yet"
    static let pluginNotificationsUnavailable = "Notifications are unavailable for this dashboard's plugin."
    static let pluginCardsUnavailable = "Approval and clarify cards are unavailable for this profile."
    static let pluginEncryptionUnavailable = "Not end-to-end encrypted, so notifications from this host show only generic text and don't open the chat."
    static let pluginRotationUnavailable = "End-to-end encrypted. Only this iPhone can read these notifications; the relay sees when they arrive, not what they say. Automatic key rotation is unavailable."
    static let loading = "読み込み中"
    static let notFetched = "未取得"
    static let needsAttention = "要確認"
    static let refreshedAt = "更新時刻"
    static let notConnected = "未接続"
    static let noItems = "0件"
    static let never = "—"

    // MARK: Bridge

    static let bridgeNotPairedBody = "この端末はMacとペアリングされていません。"
}

#endif
