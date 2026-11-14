#if LAA_BUILD
import CryptoKit
import Foundation
import UIKit
import UserNotifications

/// One answer given from a notification's button (on the iPhone, the Mac or
/// the Apple Watch), kept on the device until its outcome is known.
struct LAAQuickAnswerRequest: Codable, Equatable, Identifiable {
    enum Target: Codable, Equatable {
        case board(id: String, optionIndex: Int)
        case question(sessionID: String, requestHash: String, optionIndex: Int)
        case approval(sessionID: String, requestHash: String, allow: Bool)
    }
    /// Names the notification the answer came from; also the Bridge request
    /// id and Idempotency-Key, so a repeat is replayed, never a second answer.
    let id: String
    let target: Target
    /// What the owner chose, as the button read.
    let label: String
    /// The notification's title, for the confirmation.
    let title: String
    let link: String
    let createdAt: Date
    /// After this the answer is dropped, not sent.
    let expiresAt: Date
    var attempts = 0

    var path: String {
        switch target {
        case .board(let id, _): return "/v1/decisions/\(id)/answer"
        case .question(let sessionID, _, _), .approval(let sessionID, _, _): return "/v1/sessions/\(sessionID)/quick-reply"
        }
    }

    /// The request bytes. A board answer says `quick`, which makes the Bridge
    /// refuse it once the decision's deadline has passed; a conversation's
    /// question is answered only while its pending request still has this hash.
    var body: Data {
        let object: [String: Any]
        switch target {
        case .board(_, let optionIndex):
            object = ["optionIndex": optionIndex, "note": NSNull(), "requestId": id, "quick": true]
        case .question(_, let requestHash, let optionIndex):
            object = ["requestHash": requestHash, "choice": ["optionIndex": optionIndex]]
        case .approval(_, let requestHash, let allow):
            object = ["requestHash": requestHash, "choice": allow ? "allow" : "deny"]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// A stable id for one notification: the same tap, repeated, is the same request.
    static func identifier(notificationKey: String) -> String {
        "quick-" + SHA256.hash(data: Data(notificationKey.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the Bridge said about one attempt.
enum LAAQuickAnswerResult: Equatable {
    /// It reached the conversation that asked.
    case delivered
    /// Accepted; the Bridge delivers it itself when the conversation's turn ends.
    case waiting
    /// Saved for a caller that has no conversation.
    case stored
    /// Saved, but the conversation did not receive it: the board shows it.
    case notDelivered
    /// Refused with nothing recorded (the Bridge's code).
    case refused(String?)
    /// No answer from the Bridge: the same request may be sent again.
    case unknown
}

/// What the owner is told, as a local notification.
struct LAAQuickAnswerNotice: Equatable {
    enum Tone: Equatable { case confirmation, attention }
    let id: String
    let title: String
    let body: String
    let link: String
    let tone: Tone
}

enum LAAQuickAnswerCopy {
    static let sent = "回答を届けました"
    static let waiting = "回答を受け付けました"
    static let waitingDetail = "会話が空き次第、自動で届けます。"
    static let stored = "回答を記録しました"
    static let notDelivered = "回答は保存済みですが、届いていません"
    static let notAnswered = "回答していません"
    static let queued = "未送信です"
    static let gaveUp = "回答を届けられませんでした"
    static let openBoard = "判断ボードで確認してください。"

    static func queuedDetail(until: Date, now: Date) -> String {
        "Macへ接続でき次第、自動で届けます（\(remaining(until: until, now: now))以内）。"
    }

    static func remaining(until: Date, now: Date) -> String {
        let minutes = max(1, Int(until.timeIntervalSince(now) / 60))
        return minutes < 60 ? "\(minutes)分" : "\(minutes / 60)時間"
    }

    /// Why nothing was answered, in the owner's words. Codes come from the Bridge.
    static func refusal(_ code: String?) -> String {
        switch code {
        case "decision_expired", "expired": return "期限が過ぎています。" + openBoard
        case "decision_closed": return "すでに回答済みか、取り下げられています。"
        case "duplicate": return "この通知からはすでに回答しています。"
        case "pending_request_changed", "stale_decision": return "質問が変わりました。Workで確認してください。"
        case "quick_reply_unsupported", "question_unsupported", "decision_invalid", "invalid":
            return "この通知からは回答できません。" + openBoard
        case "not_found": return "依頼元が見つかりません。"
        case "reply_unconfirmed": return "回答の反映を確認できませんでした。Workで確認してください。"
        case "untrusted": return "通知を確認できませんでした。" + openBoard
        case "unpaired": return "Macと接続されていません。LAAアプリを開いて確認してください。"
        default: return "Macが回答を受け付けませんでした。" + openBoard
        }
    }
}

/// The answers still to be sent and the notifications already answered, in
/// one small file. Every change is written before anything is sent.
final class LAAQuickAnswerStore {
    struct State: Codable, Equatable {
        var pending: [LAAQuickAnswerRequest] = []
        /// Request ids that were given an answer, with when.
        var answered: [String: Date] = [:]
    }
    /// How long a notification stays answered: longer than any wait.
    static let memory: TimeInterval = 72 * 60 * 60

    private let file: URL
    init(file: URL = LAAQuickAnswerStore.defaultFile) { self.file = file }

    static var defaultFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LAA", isDirectory: true).appendingPathComponent("quick-answers.json")
    }

    func read() -> State {
        guard let data = try? Data(contentsOf: file),
              let state = try? Self.decoder.decode(State.self, from: data) else { return State() }
        return state
    }

    /// False when the file could not be written: the caller then sends nothing.
    @discardableResult func write(_ state: State) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Readable in the background on a locked device, once it has been unlocked.
            try Self.encoder.encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
}

/// Sends an answer given from a notification and keeps it safe on the way:
/// one answer per notification, nothing after its deadline, and an answer the
/// Bridge has not confirmed is repeated with the same request id until it is
/// confirmed, refused or too old.
@MainActor final class LAAQuickAnswerCenter {
    static let shared = LAAQuickAnswerCenter()
    /// An answer nobody could deliver for this long is dropped.
    static let maxWait: TimeInterval = 24 * 60 * 60

    typealias Send = (LAAQuickAnswerRequest) async -> LAAQuickAnswerResult
    private let store: LAAQuickAnswerStore
    private let send: Send
    private let post: (LAAQuickAnswerNotice) -> Void
    private let now: () -> Date
    private var sending = Set<String>()

    init(store: LAAQuickAnswerStore = .init(), send: @escaping Send = LAAQuickAnswerCenter.bridgeSend,
         post: @escaping (LAAQuickAnswerNotice) -> Void = LAAQuickAnswerNotifications.post,
         now: @escaping () -> Date = Date.init) {
        self.store = store; self.send = send; self.post = post; self.now = now
    }

    var pending: [LAAQuickAnswerRequest] { store.read().pending }

    /// The owner tapped `choice` on the notification `meta` came from.
    /// `notificationKey` names that one notification.
    func answer(meta: LAANotificationMeta, choice: LAANotificationActions.Choice, notificationKey: String, title: String) async {
        let id = LAAQuickAnswerRequest.identifier(notificationKey: notificationKey)
        let refuse = { (code: String) in
            self.post(.init(id: id, title: LAAQuickAnswerCopy.notAnswered, body: Self.line(title, LAAQuickAnswerCopy.refusal(code)),
                            link: meta.link, tone: .attention))
        }
        guard let quick = meta.quick, let (target, label) = Self.target(quick, choice) else { refuse("invalid"); return }
        let current = now()
        if let deadline = meta.deadline, deadline < current { refuse("expired"); return }
        var state = pruned(store.read(), at: current)
        // One answer per notification: a second tap, or a tap on the Watch
        // and another on the iPhone, never becomes a second answer.
        guard state.answered[id] == nil else { refuse("duplicate"); return }
        let expires = min(meta.deadline ?? .distantFuture, current.addingTimeInterval(Self.maxWait))
        let request = LAAQuickAnswerRequest(id: id, target: target, label: label, title: title, link: meta.link,
                                            createdAt: current, expiresAt: expires)
        state.answered[id] = current
        state.pending.append(request)
        guard store.write(state) else { refuse("invalid"); return }
        await attempt(request, first: true)
    }

    /// Sends what is still waiting: when the app comes forward, and when a
    /// push wakes it. An answer past its time is dropped and the owner told.
    func retryPending() async {
        let current = now()
        let state = store.read()
        for request in state.pending where !sending.contains(request.id) {
            if request.expiresAt < current {
                remove(request.id)
                post(.init(id: request.id, title: LAAQuickAnswerCopy.gaveUp,
                           body: Self.line(request.title, LAAQuickAnswerCopy.openBoard), link: request.link, tone: .attention))
            } else {
                await attempt(request, first: false)
            }
        }
    }

    private func attempt(_ request: LAAQuickAnswerRequest, first: Bool) async {
        guard sending.insert(request.id).inserted else { return }
        defer { sending.remove(request.id) }
        let result = await send(request)
        let chosen = "「\(request.label)」"
        switch result {
        case .delivered:
            remove(request.id)
            post(.init(id: request.id, title: LAAQuickAnswerCopy.sent, body: Self.line(request.title, chosen), link: request.link, tone: .confirmation))
        case .waiting:
            remove(request.id)
            post(.init(id: request.id, title: LAAQuickAnswerCopy.waiting,
                       body: Self.line(request.title, chosen + " " + LAAQuickAnswerCopy.waitingDetail), link: request.link, tone: .confirmation))
        case .stored:
            remove(request.id)
            post(.init(id: request.id, title: LAAQuickAnswerCopy.stored, body: Self.line(request.title, chosen), link: request.link, tone: .confirmation))
        case .notDelivered:
            remove(request.id)
            post(.init(id: request.id, title: LAAQuickAnswerCopy.notDelivered,
                       body: Self.line(request.title, LAAQuickAnswerCopy.openBoard), link: request.link, tone: .attention))
        case .refused(let code):
            remove(request.id)
            post(.init(id: request.id, title: LAAQuickAnswerCopy.notAnswered,
                       body: Self.line(request.title, LAAQuickAnswerCopy.refusal(code)), link: request.link, tone: .attention))
        case .unknown:
            var state = store.read()
            if let index = state.pending.firstIndex(where: { $0.id == request.id }) {
                state.pending[index].attempts += 1
                store.write(state)
            }
            // Said once; later attempts stay silent until there is an outcome.
            if first {
                post(.init(id: request.id, title: LAAQuickAnswerCopy.queued,
                           body: Self.line(request.title, chosen + " " + LAAQuickAnswerCopy.queuedDetail(until: request.expiresAt, now: now())),
                           link: request.link, tone: .attention))
            }
        }
    }

    private func remove(_ id: String) {
        var state = store.read()
        state.pending.removeAll { $0.id == id }
        store.write(state)
    }

    private func pruned(_ state: LAAQuickAnswerStore.State, at current: Date) -> LAAQuickAnswerStore.State {
        var next = state
        let waiting = Set(state.pending.map(\.id))
        next.answered = state.answered.filter { waiting.contains($0.key) || current.timeIntervalSince($0.value) < LAAQuickAnswerStore.memory }
        return next
    }

    private static func line(_ title: String, _ detail: String) -> String {
        title.isEmpty ? detail : "\(title)\n\(detail)"
    }

    static func target(_ quick: LAANotificationMeta.Quick, _ choice: LAANotificationActions.Choice) -> (LAAQuickAnswerRequest.Target, String)? {
        switch (quick, choice) {
        case (.board(let id, let options), .option(let index)) where options.indices.contains(index):
            return (.board(id: id, optionIndex: index), options[index])
        case (.question(let sessionID, let hash, let options), .option(let index)) where options.indices.contains(index):
            return (.question(sessionID: sessionID, requestHash: hash, optionIndex: index), options[index])
        case (.approval(let sessionID, let hash), .allow):
            return (.approval(sessionID: sessionID, requestHash: hash, allow: true), "許可")
        case (.approval(let sessionID, let hash), .deny):
            return (.approval(sessionID: sessionID, requestHash: hash, allow: false), "拒否")
        default: return nil
        }
    }

    /// The outcome of a Bridge refusal: a code the Bridge confirms recorded
    /// nothing ends the request; anything else may be repeated.
    static func result(for error: LAABridgeHTTPError) -> LAAQuickAnswerResult {
        if error.status == 401 || error.status == 403 { return .refused("unpaired") }
        if LAAWorkHTTP.outcomeUnknown(error) { return .unknown }
        return .refused(error.status == 404 ? "not_found" : error.code)
    }

    /// The outcome a board answer's record shows.
    static func result(for decision: LAADecision) -> LAAQuickAnswerResult {
        switch decision.delivery?.state {
        case "delivered": return .delivered
        case "stored": return .stored
        case "pending": return .waiting
        case "failed": return .notDelivered
        default: return .unknown
        }
    }

    private struct Accepted: Decodable {}

    /// The existing Bridge client and pairing; a background launch reads the
    /// credentials again, since the Keychain may have been locked at start.
    static func bridgeSend(_ request: LAAQuickAnswerRequest) async -> LAAQuickAnswerResult {
        let bridge = LAABridgeSession()
        bridge.retryReadingCredentialsIfNeeded()
        switch bridge.status {
        case .paired: break
        case .keychainError: return .unknown
        default: return .refused("unpaired")
        }
        guard let key = LAABridgeIdempotencyKey(restoring: request.id) else { return .refused("invalid") }
        do {
            if case .board = request.target {
                let response: LAABridgeResponse<LAADecisionAnswerResult> = try await bridge.request(
                    method: "POST", path: request.path, jsonBody: request.body, idempotencyKey: key, timeout: 20)
                return result(for: response.data.decision)
            }
            let _: LAABridgeResponse<Accepted> = try await bridge.request(
                method: "POST", path: request.path, jsonBody: request.body, idempotencyKey: key, timeout: 25)
            return .delivered
        } catch let error as LAABridgeHTTPError {
            return result(for: error)
        } catch {
            return .unknown
        }
    }
}

/// The notification side: the tap on an answer button, the notices the
/// center posts, and the tap on one of those.
enum LAAQuickAnswerNotifications {
    static let noticePrefix = "laa-quick-answer-"
    static let linkKey = "laa_link"

    static func isNotice(_ request: UNNotificationRequest) -> Bool {
        request.identifier.hasPrefix(noticePrefix) && !(request.trigger is UNPushNotificationTrigger)
    }

    static func handles(_ response: UNNotificationResponse) -> Bool {
        LAANotificationActions.isAnswer(response.actionIdentifier) || isNotice(response.notification.request)
    }

    @MainActor static func handle(_ response: UNNotificationResponse) async {
        let request = response.notification.request
        if isNotice(request) {
            if let link = request.content.userInfo[linkKey] as? String, let url = URL(string: link) {
                LAAWorkLinkRequest.shared.open(url)
            }
            return
        }
        guard let choice = LAANotificationActions.choice(for: response.actionIdentifier) else { return }
        // The answer is sent while the app stays in the background.
        let hold = UIApplication.shared.beginBackgroundTask(withName: "laa.quick-answer")
        defer { if hold != .invalid { UIApplication.shared.endBackgroundTask(hold) } }
        // Only what the sealed push itself says is acted on, never what the
        // notification's visible fields or category claim.
        guard let source = PushNotificationService.shared.laaBridgeNotification(request.content.userInfo),
              let meta = LAANotificationMeta.parse(source.sessionID) else {
            post(.init(id: LAAQuickAnswerRequest.identifier(notificationKey: request.identifier),
                       title: LAAQuickAnswerCopy.notAnswered, body: LAAQuickAnswerCopy.refusal("untrusted"),
                       link: "laa://work/decisions", tone: .attention))
            return
        }
        await LAAQuickAnswerCenter.shared.answer(meta: meta, choice: choice,
                                                 notificationKey: source.key ?? request.identifier,
                                                 title: request.content.title)
    }

    static func content(for notice: LAAQuickAnswerNotice) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.userInfo = [linkKey: notice.link]
        content.threadIdentifier = "laa-quick-answer"
        // A confirmation is quiet; anything the owner has to look at sounds.
        content.sound = notice.tone == .attention ? .default : nil
        return content
    }

    static func post(_ notice: LAAQuickAnswerNotice) {
        // The same id replaces the earlier notice about the same answer.
        let request = UNNotificationRequest(identifier: noticePrefix + notice.id, content: content(for: notice), trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
#endif
