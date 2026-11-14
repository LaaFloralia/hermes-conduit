#if LAA_BUILD
import CryptoKit
import Foundation
import UserNotifications

/// What the LAA Bridge says about one of its notifications, carried in the
/// push's `session_id` as `laa-bridge:<link>#<base64url JSON>` (the notifier
/// seals a fixed set of fields, and the session id is the one the Bridge
/// owns). The notification extension reads it to attach answer buttons and
/// quiet delivery; the app reads it again from the verified envelope when a
/// button is tapped, on the iPhone, the Mac or the Apple Watch.
struct LAANotificationMeta: Equatable {
    /// An answer that can be given from the notification itself.
    enum Quick: Equatable {
        /// A decision on the board: its id and its options in stored order.
        case board(id: String, options: [String])
        /// One question a Work conversation is waiting on.
        case question(sessionID: String, requestHash: String, options: [String])
        /// One tool a Work conversation asks to run.
        case approval(sessionID: String, requestHash: String)
    }

    static let prefix = "laa-bridge:"
    /// The Bridge's kind: `decision.new`, `session.question`, ...
    let kind: String
    /// Delivered to Notification Center without sound or a tap on the wrist.
    let quiet: Bool
    /// The link the notification opens, without the metadata.
    let link: String
    /// The board decision's deadline, when it has one.
    let deadline: Date?
    let quick: Quick?

    static func parse(_ sessionID: String?) -> LAANotificationMeta? {
        guard let sessionID, sessionID.hasPrefix(prefix),
              let mark = sessionID.lastIndex(of: "#") else { return nil }
        let link = String(sessionID[sessionID.index(sessionID.startIndex, offsetBy: prefix.count)..<mark])
        guard let url = URL(string: link), url.scheme == "laa",
              let data = base64URLDecoded(String(sessionID[sessionID.index(after: mark)...])),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["v"] as? Int) == 1,
              let kind = object["k"] as? String, !kind.isEmpty, kind.utf8.count < 41 else { return nil }
        let options = (object["o"] as? [Any])?.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        let answerable = (2...6).contains(options.count) && options.allSatisfy { !$0.isEmpty }
            && options.count == (object["o"] as? [Any])?.count
        let parts = url.pathComponents
        var quick: Quick?
        switch kind {
        case "decision.new":
            // The id in the metadata must be the decision the link opens.
            if let id = object["id"] as? String, isDecisionID(id), answerable,
               url.host == "work", parts.count == 3, parts[1] == "decisions", parts[2] == id {
                quick = .board(id: id, options: options)
            }
        case "session.question", "session.approval":
            if let sid = object["sid"] as? String, isSessionID(sid),
               let hash = object["h"] as? String, isHash(hash),
               url.host == "work", parts.count == 3, parts[1] == "sessions", parts[2] == sid {
                if kind == "session.question", answerable {
                    quick = .question(sessionID: sid, requestHash: hash, options: options)
                } else if kind == "session.approval", (object["a"] as? Int) == 1 {
                    quick = .approval(sessionID: sid, requestHash: hash)
                }
            }
        default: break
        }
        let deadline = (object["d"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return LAANotificationMeta(kind: kind, quiet: (object["lv"] as? String) == "p", link: link,
                                   deadline: deadline, quick: quick)
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        guard !value.isEmpty, value.utf8.count < 700 else { return nil }
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        return Data(base64Encoded: text)
    }

    private static func isDecisionID(_ value: String) -> Bool {
        value.hasPrefix("dec_") && value.count == 20 && value.dropFirst(4).allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func isSessionID(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        return (1...200).contains(value.utf8.count) && value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// The category seam, so the registration can be tested without the system
/// notification center.
protocol LAANotificationCategoryCenter: AnyObject {
    func laaCategories(_ completion: @escaping (Set<UNNotificationCategory>) -> Void)
    func laaSetCategories(_ categories: Set<UNNotificationCategory>)
    func laaDeliveredCategoryIdentifiers(_ completion: @escaping (Set<String>) -> Void)
}

extension UNUserNotificationCenter: LAANotificationCategoryCenter {
    func laaCategories(_ completion: @escaping (Set<UNNotificationCategory>) -> Void) {
        getNotificationCategories(completionHandler: completion)
    }
    func laaSetCategories(_ categories: Set<UNNotificationCategory>) { setNotificationCategories(categories) }
    func laaDeliveredCategoryIdentifiers(_ completion: @escaping (Set<String>) -> Void) {
        getDeliveredNotifications { completion(Set($0.map(\.request.content.categoryIdentifier))) }
    }
}

/// The answer buttons on a Bridge notification. iOS mirrors them to the Apple
/// Watch, and the tap comes back to the iPhone app, which sends the answer.
enum LAANotificationActions {
    enum Choice: Equatable { case option(Int), allow, deny }

    static let categoryPrefix = "LAA_ANSWER_"
    static let optionActionPrefix = "LAA_ANSWER_OPTION_"
    static let allowAction = "LAA_ANSWER_ALLOW"
    static let denyAction = "LAA_ANSWER_DENY"
    /// A wrist-sized label; the notification's own text carries the rest.
    static let maxTitleLength = 40
    /// Categories kept before the ones no delivered notification uses are dropped.
    static let maxCategories = 40

    static func isAnswer(_ actionIdentifier: String) -> Bool { actionIdentifier.hasPrefix(categoryPrefix) }

    static func choice(for actionIdentifier: String) -> Choice? {
        if actionIdentifier == allowAction { return .allow }
        if actionIdentifier == denyAction { return .deny }
        guard actionIdentifier.hasPrefix(optionActionPrefix),
              let index = Int(actionIdentifier.dropFirst(optionActionPrefix.count)), (0..<6).contains(index) else { return nil }
        return .option(index)
    }

    static func title(_ label: String) -> String {
        let clean = label.split(whereSeparator: \.isNewline).joined(separator: " ")
        return clean.count > maxTitleLength ? String(clean.prefix(maxTitleLength - 1)) + "…" : clean
    }

    /// Every answer needs the device unlocked: a locked iPhone asks for the
    /// owner first, and a Watch on the wrist already has.
    static func actions(for quick: LAANotificationMeta.Quick) -> [UNNotificationAction] {
        switch quick {
        case .board(_, let options), .question(_, _, let options):
            return options.enumerated().map { index, label in
                UNNotificationAction(identifier: "\(optionActionPrefix)\(index)", title: title(label),
                                     options: [.authenticationRequired])
            }
        case .approval:
            return [
                UNNotificationAction(identifier: allowAction, title: "許可", options: [.authenticationRequired]),
                UNNotificationAction(identifier: denyAction, title: "拒否", options: [.authenticationRequired, .destructive]),
            ]
        }
    }

    /// One category per distinct set of buttons, named by their content, so
    /// the same choices reuse it and the app can tell its own apart.
    static func category(for quick: LAANotificationMeta.Quick) -> UNNotificationCategory {
        let actions = actions(for: quick)
        let digest = SHA256.hash(data: Data(actions.map { "\($0.identifier)\u{1F}\($0.title)" }.joined(separator: "\u{1E}").utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return UNNotificationCategory(identifier: categoryPrefix + name, actions: actions, intentIdentifiers: [], options: [])
    }

    /// The categories to register when `added` joins `existing`: everything
    /// that isn't an answer category stays, and once there are too many,
    /// answer categories no delivered notification shows are dropped.
    static func merged(existing: Set<UNNotificationCategory>, adding added: UNNotificationCategory,
                       delivered: Set<String>) -> Set<UNNotificationCategory> {
        var kept = existing.filter { $0.identifier != added.identifier }
        if kept.filter({ $0.identifier.hasPrefix(categoryPrefix) }).count >= maxCategories {
            kept = kept.filter { !$0.identifier.hasPrefix(categoryPrefix) || delivered.contains($0.identifier) }
        }
        kept.insert(added)
        return kept
    }

    /// Called by the notification extension with the verified session id:
    /// quiet delivery and the answer buttons. `completion` always runs once.
    static func decorate(_ content: UNMutableNotificationContent, sessionID: String?, now: Date = Date(),
                         center: LAANotificationCategoryCenter = UNUserNotificationCenter.current(),
                         completion: @escaping () -> Void) {
        guard let meta = LAANotificationMeta.parse(sessionID) else { completion(); return }
        if meta.quiet {
            content.sound = nil
            content.interruptionLevel = .passive
        }
        // A decision past its deadline is shown, but not answered from here.
        guard let quick = meta.quick, !(meta.deadline.map { $0 < now } ?? false) else { completion(); return }
        let category = category(for: quick)
        center.laaCategories { existing in
            center.laaDeliveredCategoryIdentifiers { delivered in
                center.laaSetCategories(merged(existing: existing, adding: category, delivered: delivered))
                // Read back before the notification is shown, so the system
                // has the new category when it looks the identifier up.
                center.laaCategories { _ in
                    content.categoryIdentifier = category.identifier
                    completion()
                }
            }
        }
    }

    /// The app's own registration replaces the whole set; this keeps the
    /// answer categories delivered notifications still show.
    static func registering(_ own: Set<UNNotificationCategory>, center: LAANotificationCategoryCenter = UNUserNotificationCenter.current()) {
        center.laaCategories { existing in
            center.laaSetCategories(own.union(existing.filter { $0.identifier.hasPrefix(categoryPrefix) }))
        }
    }
}
#endif
