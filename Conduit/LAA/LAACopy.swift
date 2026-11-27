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

    static let instructionFiles = "Instruction Files"
    static let instructionFileNames = "AGENTS.md / CLAUDE.md"
    static let brand = "LAA"
    static let agent = "Monet"
    static let settings = "Settings"
    /// The Today tab's fourth segment. English like the tab names; not an upstream catalog key.
    static let habitsMode = "Habits"
    static let loginMacAddress = "Mac Address"
    static let loginMacSubtitle = "Connect to Mac"
    static let plugin = "Connection Status"
    static let pairingTitle = "Connect to Mac"
    static let pairingAddress = "Address"
    static let pairingCode = "Pairing Code"
    static let pairingConnect = "Connect"
    static let mac = "Mac"
    static let macRePair = "Reconnect"
    static let macRefresh = "Retry"
    static let macChecking = "Connecting"
    static let macConnected = "Connected"
    static let macOffline = "Disconnected"
    static let macNotPaired = "Disconnected"
    static let macRePairRequired = "Disconnected"
    static let macKeychainError = "認証情報を読み取れません"
    static let macConnectionError = "接続できません"
    static let macConnectingBody = "Connecting"
    static let macVoiceSettingsUnavailable = "Macの音声設定が応答しません。接続を確認してください。"
    static let callsFromMonet = "Incoming Calls"
    static let callsFromMonetDetail = "Call Preferences"
    static let screenQuestionAddShortcut = "Add Shortcut"
    static let dataAndLicenses = "Data & Licenses"
    static let dataAndLicensesDetail = "Data & Licenses"
    static let openSourceLicenses = "Open-source Licenses"
    static let back = "Back"
    static let cancel = "Cancel"
    static let save = "Save"
    static let call = "Call"
    static let callMute = "Mute"
    static let callUnmute = "Unmute"
    static let callSpeaker = "Speaker"
    static let callChat = "Chat"
    static let callEnd = "End"
    static let callAudioRoute = "Audio Output"
    static let callReceiver = "Receiver"
    static let callNoOutput = "No Audio Output"
    static let callReturn = "Call"
    static let pluginVersion = "Version"
    static let pluginDashboard = "Mac"
    static let pluginConnection = "Connect"
    static let pluginConnected = "Connected"
    static let pluginNotConnected = "Disconnected"
    static let pluginUnavailable = "Unavailable"
    static let pluginChecking = "Connecting"
    static let pluginNotChecked = "Unknown"
    static let pluginNotificationsUnavailable = "このMacでは通知を利用できません"
    static let pluginCardsUnavailable = "このAI社員は確認カードに対応していません"
    static let pluginEncryptionUnavailable = "暗号化されていないため、通知の本文と会話への移動は利用できません"
    static let pluginRotationUnavailable = "通知はこのiPhoneだけで読める暗号化で保護されます。暗号鍵の自動更新は利用できません。"
    static let loading = "Loading"
    static let notFetched = "Unknown"
    static let needsAttention = "Review"
    static let refreshedAt = "Updated"
    static let notConnected = "Disconnected"
    static let noItems = "0件"
    static let never = "—"

    // MARK: Bridge

    static let bridgeNotPairedBody = "Macに接続してください"

    // MARK: iPhone Use (Live Activity)

    static let phoneUseAsk = "iPhoneを操作してよいですか"
    static let phoneUseOperating = "iPhoneを操作中"
    static let phoneUseAllow = "Allow"
    static let phoneUseDeny = "Deny"
    static let phoneUseStop = "Stop"
    static let phoneUseOperatingShort = "In Use"

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

    // MARK: Employee call (Live Activity)

    #if os(iOS)
    static func staffCallState(_ phase: LAAStaffCallPhase) -> String {
        switch phase {
        case .connecting: return "Connecting"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .muted: return "Muted"
        case .ended: return "Call Ended"
        }
    }
    #endif
}

#endif
