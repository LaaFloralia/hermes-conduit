#if LAA_BUILD && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation
import os
import UIKit

private let phoneUseLog = Logger(subsystem: "com.laa.conduit", category: "PhoneUse")

/// The app's half of asking before an agent operates the iPhone in use
/// (`LAAPhoneUseAttributes`): hands the Bridge the push-to-start token and
/// each activity's update token, and carries the owner's answer from the
/// Live Activity's buttons to the Bridge, then shows it on the activity.
@MainActor final class LAAPhoneUseService {
    static let shared = LAAPhoneUseService()

    private struct Registered: Decodable { let registered: Bool }
    private struct RequestView: Decodable { let id: String; let status: String }
    private struct TokenBody: Encodable { let token: String; let environment: String?; var wakeToken: String? = nil }
    private struct AnswerBody: Encodable { let answer: String }

    private let client = LAABridgeClient()
    private var started = false
    private var observed: Set<String> = []
    private var answering: Set<String> = []
    private var registeredTokens: Set<String> = []
    private var pendingStartToken: String?
    private var startToken: String?
    private var wakeToken: String?
    private var registeringStartToken = false
    private let currentStartToken: () -> Data?
    private let sendStartToken: ((String, String?) async -> Bool)?

    init(currentStartToken: @escaping () -> Data? = {
        if #available(iOS 17.2, *) { return Activity<LAAPhoneUseAttributes>.pushToStartToken }
        return nil
    }, sendStartToken: ((String, String?) async -> Bool)? = nil) {
        self.currentStartToken = currentStartToken
        self.sendStartToken = sendStartToken
    }

    /// Debug builds talk to the APNs sandbox, TestFlight to production.
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    static var usesSimulatedPush: Bool {
        let policy = LAALabNetworkPolicy.current
        let env = ProcessInfo.processInfo.environment
        guard policy.laneID != nil, env["LAA_LAB_PHONE_USE_PUSH"] == "1",
              let fixture = env["LAA_LANE_FIXTURE_PHONE_USE"], fixture == policy.bridgeAddress else { return false }
        return true
    }

    // simctl has no liveactivity push type or ActivityKit topic. Carry the
    // original Bridge APS inside an app notification and ask ActivityKit to
    // present the same attributes and state, without requesting a push token.
    func receiveSimulatedPush(_ info: [AnyHashable: Any]) async -> Bool {
        guard Self.usesSimulatedPush,
              (info["laa_lab_lane"] as? String) == LAALabNetworkPolicy.current.laneID,
              let payload = info["laa_lab_phone_use"] as? [String: Any],
              let aps = payload["aps"] as? [String: Any] else { return false }
        let event = aps["event"] as? String
        guard event == "start" else {
            guard event == "end" || Self.handlesWake(payload) else { return false }
            await refresh()
            return true
        }
        guard aps["attributes-type"] as? String == "LAAPhoneUseAttributes",
              let startData = try? JSONSerialization.data(withJSONObject: aps),
              let start = try? JSONDecoder().decode(SimulatedStart.self, from: startData),
              Self.isRequestID(start.attributes.requestID),
              !Activity<LAAPhoneUseAttributes>.activities.contains(where: { $0.attributes.requestID == start.attributes.requestID }) else { return true }
        do {
            let activity = try Activity.request(attributes: start.attributes,
                content: ActivityContent(state: start.state, staleDate: start.staleDate.map(Date.init(timeIntervalSince1970:))),
                pushType: nil)
            // A synthetic token acknowledges ActivityKit creation without
            // requesting a real APNs token. End delivery stays inside simctl.
            let token = Self.hex(Data(activity.id.utf8.prefix(120)))
            await registerActivity(requestID: start.attributes.requestID, token: token)
        } catch {
            phoneUseLog.error("simulated ActivityKit start failed: \(String(describing: error), privacy: .public)")
        }
        return true
    }

    private struct SimulatedStart: Decodable {
        let attributes: LAAPhoneUseAttributes
        let state: LAAPhoneUseAttributes.ContentState
        let staleDate: Double?
        enum CodingKeys: String, CodingKey {
            case attributes, state = "content-state", staleDate = "stale-date"
        }
    }
    #endif

    func start() {
        #if DEBUG && targetEnvironment(simulator)
        let simulated = Self.usesSimulatedPush
        #else
        let simulated = false
        #endif
        #if DEBUG
        guard simulated || LAALabNetworkPolicy.current.allowsPush else { return }
        #endif
        guard !started else { return }
        started = true
        LAAPhoneUseAnswers.handler = { requestID, answer in
            await LAAPhoneUseService.shared.answer(requestID: requestID, answer: answer)
        }
        if !simulated, #available(iOS 17.2, *) {
            Task {
                for await data in Activity<LAAPhoneUseAttributes>.pushToStartTokenUpdates {
                    await registerStart(token: Self.hex(data))
                }
            }
        }
        Task {
            for await activity in Activity<LAAPhoneUseAttributes>.activityUpdates { observe(activity) }
        }
        Task { await refresh() }
        // The app's push token, for the Mac's wake (no prompt: it only reads the token).
        if !simulated { UIApplication.shared.registerForRemoteNotifications() }
        // Not paired yet, or offline at launch: try again when the app is opened.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                await LAAPhoneUseService.shared.refresh()
            }
        }
    }

    /// Every activity on screen, whenever the app runs: hand the Bridge any
    /// update token it lacks (an activity started while the app was suspended
    /// may not have come through `activityUpdates`), then match the activity
    /// to its request. iOS need not wake the app with the update token of an
    /// activity a push started, so the Mac's end push may never reach it: an
    /// activity whose request closed, or whose answer time passed, ends here.
    func refresh() async {
        // Token maintenance must not delay an owner's answer or ending an activity.
        Task { await refreshStartToken() }
        for activity in Activity<LAAPhoneUseAttributes>.activities {
            observe(activity)
            let requestID = activity.attributes.requestID
            if let data = activity.pushToken {
                await registerActivity(requestID: requestID, token: Self.hex(data))
            }
            if let status = await requestStatus(requestID), status != "pending" {
                if !answering.contains(requestID) { await show(status: status, for: requestID) }
            } else if activity.content.state.usePhase == .ask, activity.attributes.answerDate < Date() {
                await show(status: "expired", for: requestID)
            }
        }
    }

    /// The request's state on the Bridge; nil when it can't be read (offline).
    private func requestStatus(_ requestID: String) async -> String? {
        guard Self.isRequestID(requestID), let credentials = credentials() else { return nil }
        do {
            let response: LAABridgeResponse<RequestView> = try await client.request(
                method: "GET", path: "/v1/phone-use/requests/\(requestID)", credentials: credentials)
            return response.data.status
        } catch let error as LAABridgeHTTPError where error.code == "phone_use_not_found" {
            return "expired"
        } catch {
            return nil
        }
    }

    private func credentials() -> LAABridgeCredentials? { try? LAABridgeKeychain().read() }

    /// The app's own push token: the Mac wakes the app with it to take down
    /// an activity whose update token never came (see `refresh`).
    func setWakeToken(_ data: Data) {
        let token = Self.hex(data)
        guard token != wakeToken else { return }
        phoneUseLog.info("app push token received")
        wakeToken = token
        Task { await refreshStartToken() }
    }

    func wakeTokenFailed(_ error: Error) {
        phoneUseLog.error("no app push token: \(String(describing: error), privacy: .public)")
    }

    /// A background push from the Mac (`laa_phone_use`): an activity it
    /// could not end by push. True when the push was this kind.
    static func handlesWake(_ userInfo: [AnyHashable: Any]) -> Bool { userInfo["laa_phone_use"] != nil }

    /// Reconcile the current ActivityKit token whenever the app runs again,
    /// even if the earlier registration succeeded and no update was observed.
    func refreshStartToken() async {
        #if DEBUG && targetEnvironment(simulator)
        if Self.usesSimulatedPush {
            wakeToken = String(repeating: "02", count: 32)
            await registerStart(token: String(repeating: "01", count: 32))
            return
        }
        #endif
        let token = currentStartToken().map(Self.hex) ?? pendingStartToken ?? startToken
        if let token { await registerStart(token: token) }
    }

    private func registerStart(token: String) async {
        pendingStartToken = token
        startToken = token
        // Foreground refresh, token updates and the app's push token can arrive
        // together. Complete older writes before registering the newest pair.
        guard !registeringStartToken else { return }
        registeringStartToken = true
        defer { registeringStartToken = false }
        while let pending = pendingStartToken {
            let wake = wakeToken
            let registered = await writeStartToken(token: pending, wakeToken: wake)
            if pendingStartToken == pending && wakeToken == wake {
                if registered { pendingStartToken = nil }
                return
            }
        }
    }

    private func writeStartToken(token: String, wakeToken: String?) async -> Bool {
        if let sendStartToken { return await sendStartToken(token, wakeToken) }
        guard let credentials = credentials() else { return false }
        do {
            let body = try JSONEncoder().encode(TokenBody(token: token, environment: Self.environment, wakeToken: wakeToken))
            let response: LAABridgeResponse<Registered> = try await client.request(
                method: "PUT", path: "/v1/phone-use/start-token", jsonBody: body, credentials: credentials)
            return response.data.registered
        } catch {
            phoneUseLog.error("start token not registered: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func observe(_ activity: Activity<LAAPhoneUseAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        let requestID = activity.attributes.requestID
        Task {
            for await data in activity.pushTokenUpdates {
                await registerActivity(requestID: requestID, token: Self.hex(data))
            }
        }
    }

    private func registerActivity(requestID: String, token: String) async {
        guard !registeredTokens.contains(token), let credentials = credentials() else { return }
        do {
            let body = try JSONEncoder().encode(TokenBody(token: token, environment: nil))
            let _: LAABridgeResponse<RequestView> = try await client.request(
                method: "PUT", path: "/v1/phone-use/requests/\(requestID)/activity-token", jsonBody: body, credentials: credentials)
            registeredTokens.insert(token)
        } catch {
            phoneUseLog.error("activity token not registered: \(String(describing: error), privacy: .public)")
        }
    }

    /// The owner's tap. The Bridge decides; the activity shows its decision.
    /// A request the Bridge already closed (time ran out) ends here too.
    func answer(requestID: String, answer: LAAPhoneUseAnswer) async {
        guard Self.isRequestID(requestID), answering.insert(requestID).inserted else { return }
        defer { answering.remove(requestID) }
        await refresh()
        guard let credentials = credentials() else { return }
        let status: String
        do {
            let body = try JSONEncoder().encode(AnswerBody(answer: answer.rawValue))
            let response: LAABridgeResponse<RequestView> = try await client.request(
                method: "POST", path: "/v1/phone-use/requests/\(requestID)/answer", jsonBody: body,
                credentials: credentials, timeout: 15)
            status = response.data.status
        } catch let error as LAABridgeHTTPError where error.code == "phone_use_closed" || error.code == "phone_use_not_found" {
            status = answer == .stop ? "stopped" : "expired"
        } catch {
            // Unreachable: leave the question up so the owner can tap again.
            phoneUseLog.error("answer not delivered: \(String(describing: error), privacy: .public)")
            return
        }
        await show(status: status, for: requestID)
    }

    private func show(status: String, for requestID: String) async {
        for activity in Activity<LAAPhoneUseAttributes>.activities where activity.attributes.requestID == requestID {
            let now = Date()
            switch status {
            case "allowed":
                guard activity.content.state.usePhase == .ask else { continue }
                let state = LAAPhoneUseAttributes.ContentState(phase: LAAPhoneUsePhase.operating.rawValue, since: now.timeIntervalSince1970)
                await activity.update(ActivityContent(state: state, staleDate: now.addingTimeInterval(1800)))
            default:
                let phase: LAAPhoneUsePhase = switch status {
                case "denied": .denied
                case "stopped": .stopped
                case "expired": .expired
                default: .ended
                }
                let state = LAAPhoneUseAttributes.ContentState(phase: phase.rawValue, endedAt: now.timeIntervalSince1970)
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(now.addingTimeInterval(4)))
            }
        }
    }

    nonisolated static func isRequestID(_ value: String) -> Bool {
        value.range(of: "^pu_[0-9a-f]{16}$", options: .regularExpression) != nil
    }

    nonisolated static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
#endif
