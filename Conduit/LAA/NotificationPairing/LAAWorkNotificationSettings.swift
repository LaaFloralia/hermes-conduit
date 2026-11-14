#if LAA_BUILD
import SwiftUI

/// Which of the Mac's own notifications reach the owner, and how loudly: one
/// set on the Bridge, so the iPhone, the Macs and the Apple Watch agree.
struct LAAWorkNotificationPreferences: Codable, Equatable {
    enum Level: String, Codable, CaseIterable, Identifiable {
        case alert, quiet, off
        var id: String { rawValue }
        /// The LAA build shows Japanese only, like LAACopy.
        private static let titles: [Level: String] = [.alert: "知らせる", .quiet: "静かに", .off: "届けない"]
        var title: String { Self.titles[self] ?? rawValue }
    }
    struct Kind: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        /// What the owner has to answer is never switched off.
        let canTurnOff: Bool
        var levels: [Level] { canTurnOff ? Level.allCases : [.alert, .quiet] }
    }
    /// The order the settings show, and the Bridge's keys.
    static let kinds: [Kind] = [
        .init(id: "decision", title: "判断", detail: "判断ボードに届いた判断。通知のボタンで回答できます", canTurnOff: false),
        .init(id: "question", title: "質問", detail: "会話が質問の回答を待っている時", canTurnOff: false),
        .init(id: "approval", title: "承認", detail: "会話が操作の許可を待っている時", canTurnOff: false),
        .init(id: "error", title: "エラー", detail: "会話がエラーで止まった時", canTurnOff: true),
        .init(id: "finished", title: "手番の終了", detail: "エージェントの手番が終わった時", canTurnOff: true),
        .init(id: "task", title: "タスク", detail: "Linearの通知", canTurnOff: true),
        .init(id: "calendar", title: "予定", detail: "予定のリマインダー", canTurnOff: true),
    ]

    var kinds: [String: Level]
    var updatedAt: String?

    init(kinds: [String: Level], updatedAt: String? = nil) { self.kinds = kinds; self.updatedAt = updatedAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A level this build does not know reads as the loud default, never as off.
        let raw = try values.decode([String: String].self, forKey: .kinds)
        kinds = raw.mapValues { Level(rawValue: $0) ?? .alert }
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func level(_ kind: String) -> Level { kinds[kind] ?? .alert }
}

@MainActor final class LAAWorkNotificationSettingsModel: ObservableObject {
    enum Phase: Equatable { case loading, loaded, unsupported, unpaired, failed(String) }
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var preferences = LAAWorkNotificationPreferences(kinds: [:])
    @Published private(set) var saving: String?

    static let path = "/v1/notifications/preferences"

    func load(_ bridge: LAABridgeSession) async {
        guard bridge.status == .paired else { phase = .unpaired; return }
        do {
            preferences = try await bridge.read(Self.path)
            phase = .loaded
        } catch is CancellationError {
        } catch let error as LAABridgeError {
            if case .other(status: 404, code: _) = error { phase = .unsupported }
            else { phase = .failed(error.japaneseText) }
        } catch { phase = .failed(LAABridgeError.invalidResponse.japaneseText) }
    }

    /// The body for one change: only the kind that changed.
    static func body(kind: String, level: LAAWorkNotificationPreferences.Level) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["kinds": [kind: level.rawValue]], options: [.sortedKeys])) ?? Data()
    }

    func set(_ kind: String, to level: LAAWorkNotificationPreferences.Level, bridge: LAABridgeSession) async {
        guard saving == nil, preferences.level(kind) != level else { return }
        saving = kind
        defer { saving = nil }
        do {
            let response: LAABridgeResponse<LAAWorkNotificationPreferences> = try await bridge.request(
                method: "PUT", path: Self.path, jsonBody: Self.body(kind: kind, level: level),
                idempotencyKey: LAABridgeIdempotencyKey(), timeout: 20)
            preferences = response.data
            phase = .loaded
        } catch let error as LAABridgeHTTPError {
            phase = .failed(error.legacyError.japaneseText)
            await load(bridge)
        } catch {
            // The change may or may not have been saved: show what the Mac holds.
            await load(bridge)
        }
    }

    #if DEBUG
    func setForTesting(_ preferences: LAAWorkNotificationPreferences, phase: Phase = .loaded) {
        self.preferences = preferences; self.phase = phase
    }
    #endif
}

/// Settings > Notifications: the Mac's own notifications, kind by kind.
struct LAAWorkNotificationSettingsSection: View {
    @StateObject private var bridge = LAABridgeSession()
    @StateObject private var model = LAAWorkNotificationSettingsModel()

    var body: some View {
        LAAWorkNotificationSettingsRows(model: model) { kind, level in
            Task { await model.set(kind, to: level, bridge: bridge) }
        }
        .task { await model.load(bridge) }
    }
}

struct LAAWorkNotificationSettingsRows: View {
    private static let sectionTitle = "Work"
    @ObservedObject var model: LAAWorkNotificationSettingsModel
    let onSelect: (String, LAAWorkNotificationPreferences.Level) -> Void

    var body: some View {
        ConduitSettingsSection(title: Self.sectionTitle, symbol: "bell.badge", tint: .conduitAccent) {
            switch model.phase {
            case .loading:
                LAALoadingDots()
            case .unpaired:
                caption("Macと接続すると、Workからの通知を選べます。")
            case .unsupported:
                caption("Macのアップデート待ちです。")
            case .failed(let message):
                caption(message)
            case .loaded:
                ForEach(LAAWorkNotificationPreferences.kinds) { kind in
                    VStack(alignment: .leading, spacing: 4) {
                        ConduitMenuPicker(
                            value: model.preferences.level(kind.id),
                            choices: kind.levels.map { (id: $0, title: $0.title) },
                            onSelect: { choice in
                                guard choice != model.preferences.level(kind.id) else { return }
                                Haptics.selection()
                                onSelect(kind.id, choice)
                            }
                        ) { Text(verbatim: kind.title) }
                        .disabled(model.saving != nil)
                        .accessibilityIdentifier("notifications.work.\(kind.id)")
                        Text(verbatim: kind.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                caption("「静かに」は、音と手首への通知なしで通知センターに入ります。iPhone・Mac・Apple Watchで共通です。")
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).font(.footnote).foregroundStyle(.secondary)
    }
}
#endif
