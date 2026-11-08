#if LAA_BUILD
import Foundation
import Combine

/// Snapshots use the existing protected, device-scoped draft store. They never
/// authorize a mutation: decisions are fetched again before an answer is sent.
@MainActor enum LAAWorkSessionCache {
    private static func key(device: String, target: String) -> ComposerDraftKey {
        ComposerDraftKey(profile: "laa-session-cache-v1", sessionID: "\(device):\(target)", dashboardID: LAAWorkDrafts.dashboardID)
    }
    static func read<T: Decodable>(_ type: T.Type, store: ComposerDraftStore, device: String?, target: String) -> T? {
        guard let device, let data = store.draft(for: key(device: device, target: target)).text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, store: ComposerDraftStore, device: String?, target: String) {
        guard let device, let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return }
        _ = store.save(ComposerDraft(text: text, attachments: []), for: key(device: device, target: target))
    }
}

@MainActor final class LAAWorkLinkRequest: ObservableObject {
    static let shared = LAAWorkLinkRequest()
    @Published var url: URL?
    @Published private(set) var generation: UInt64 = 0
    @discardableResult func open(_ url: URL) -> Bool {
        guard url.scheme == "laa", ["work", "today", "brain", "assets"].contains(url.host ?? "") else { return false }
        self.url = url
        generation &+= 1
        return true
    }
    var calendarEvent: (id: String, calendarID: String)? {
        guard url?.host == "today", let url, url.pathComponents.count == 3, url.pathComponents[1] == "events",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let calendar = components.queryItems?.first(where: { $0.name == "calendar" })?.value, !calendar.isEmpty else { return nil }
        let id = url.pathComponents[2]
        return id.isEmpty ? nil : (id, calendar)
    }
    var sessionTarget: String? {
        guard url?.host == "work", let parts = url?.pathComponents, parts.count == 3, parts[1] == "sessions" else { return nil }
        let id = parts[2]
        guard id.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil else { return nil }
        return id
    }
    /// `laa://work/decisions` (the board) or `laa://work/decisions/<id>`.
    var decisionsLink: Bool { url?.host == "work" && url?.pathComponents.dropFirst().first == "decisions" }
    var decisionTarget: String? {
        guard decisionsLink, let parts = url?.pathComponents, parts.count == 3,
              parts[2].range(of: "^dec_[0-9a-f]{16}$|^ses_[0-9a-f]{16}$", options: .regularExpression) != nil else { return nil }
        return parts[2]
    }
    var sessionID: String? {
        guard let id = sessionTarget, id.range(of: "^ses_[0-9a-f]{16}$", options: .regularExpression) != nil else { return nil }
        return id
    }
}
#endif
