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
    private struct TokenBody: Encodable { let token: String; let environment: String? }
    private struct AnswerBody: Encodable { let answer: String }

    private let client = LAABridgeClient()
    private var started = false
    private var observed: Set<String> = []
    private var answering: Set<String> = []
    private var pendingStartToken: String?

    /// Debug builds talk to the APNs sandbox, TestFlight to production.
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    func start() {
        guard !started else { return }
        started = true
        LAAPhoneUseAnswers.handler = { requestID, answer in
            await LAAPhoneUseService.shared.answer(requestID: requestID, answer: answer)
        }
        if #available(iOS 17.2, *) {
            Task {
                for await data in Activity<LAAPhoneUseAttributes>.pushToStartTokenUpdates {
                    await registerStart(token: Self.hex(data))
                }
            }
        }
        Task {
            for await activity in Activity<LAAPhoneUseAttributes>.activityUpdates { observe(activity) }
        }
        for activity in Activity<LAAPhoneUseAttributes>.activities { observe(activity) }
        // Not paired yet, or offline at launch: try again when the app is opened.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard let token = LAAPhoneUseService.shared.pendingStartToken else { return }
                await LAAPhoneUseService.shared.registerStart(token: token)
            }
        }
    }

    private func credentials() -> LAABridgeCredentials? { try? LAABridgeKeychain().read() }

    private func registerStart(token: String) async {
        pendingStartToken = token
        guard let credentials = credentials() else { return }
        do {
            let body = try JSONEncoder().encode(TokenBody(token: token, environment: Self.environment))
            let _: LAABridgeResponse<Registered> = try await client.request(
                method: "PUT", path: "/v1/phone-use/start-token", jsonBody: body, credentials: credentials)
            if pendingStartToken == token { pendingStartToken = nil }
        } catch {
            phoneUseLog.error("start token not registered: \(String(describing: error), privacy: .public)")
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
        guard let credentials = credentials() else { return }
        do {
            let body = try JSONEncoder().encode(TokenBody(token: token, environment: nil))
            let _: LAABridgeResponse<RequestView> = try await client.request(
                method: "PUT", path: "/v1/phone-use/requests/\(requestID)/activity-token", jsonBody: body, credentials: credentials)
        } catch {
            phoneUseLog.error("activity token not registered: \(String(describing: error), privacy: .public)")
        }
    }

    /// The owner's tap. The Bridge decides; the activity shows its decision.
    /// A request the Bridge already closed (time ran out) ends here too.
    func answer(requestID: String, answer: LAAPhoneUseAnswer) async {
        guard Self.isRequestID(requestID), answering.insert(requestID).inserted else { return }
        defer { answering.remove(requestID) }
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
