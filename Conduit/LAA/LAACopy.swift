#if LAA_BUILD

import Foundation

enum LAACopy {
    // MARK: Tabs

    /// The tab and navigation titles, in the order the bar shows them.
    static func tabTitle(_ tab: LAATab) -> String {
        switch tab {
        case .chats: return "会話"
        case .work: return "仕事"
        case .brain: return "Brain"
        case .source: return "素材"
        case .usage: return "Usage"
        }
    }

    // MARK: Shared controls

    static let settings = "設定"
    static let loading = "読み込み中"
    static let notFetched = "未取得"
    static let needsAttention = "要確認"
    static let refreshedAt = "更新時刻"
    static let notConnected = "未接続"
    static let noItems = "0件"
    static let never = "—"

    // MARK: Bridge (Mac-side LAA Bridge; pairing is a later task)

    /// The state the task asks for by name, so it stays in English here and
    /// the body explains it in Japanese.
    static let bridgeNotPairedTitle = "Bridge not paired"
    static let bridgeNotPairedBody = "この端末はMacのLAA Bridgeとペアリングされていません。"

    // MARK: Segments

    static func segments(_ tab: LAATab) -> [String] {
        switch tab {
        case .work: return ["セッション", "Project", "タスク", "ルーティン"]
        case .brain: return ["最近", "フォルダ", "タグ"]
        case .source: return ["Drive", "Inspiration", "Studio"]
        case .chats, .usage: return []
        }
    }

    // MARK: A tab's own line about what it will hold

    /// What the tab will show once the Bridge is paired, one line, so an
    /// empty screen explains what belongs there.
    static func emptyReason(_ tab: LAATab) -> String {
        switch tab {
        case .chats: return "まだ会話がありません。"
        case .work: return "Projectやタスクを作ると、ここに並びます。"
        case .brain: return "Brainに項目がありません。保存するとここに並びます。"
        case .source: return "まだ素材がありません。Drive・Inspiration・Studioの項目がここに並びます。"
        case .usage: return "利用枠・実利用・費用・Macの状態を、更新時刻と一緒に出します。"
        }
    }

    // MARK: Usage rows

    static let usageRows = ["利用枠", "実利用", "費用", "Macの状態"]

    // MARK: Failures

    static let failureTitle = "Bridgeから読めませんでした"
    static let failureBody = "データを取得できませんでした。Bridgeの接続を確認してください。"
}

#endif
