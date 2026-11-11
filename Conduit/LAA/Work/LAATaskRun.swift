#if LAA_BUILD
import Foundation
import SwiftUI

/// The Bridge's execution record for a task it created (contract 2026-11-09).
/// Absent on an older Bridge or for a task an agent registered: the owner is
/// then shown as 担当 and no status badge is drawn.
struct LAATaskRun: Codable, Equatable {
    struct Assignee: Codable, Equatable {
        let kind: String?
        let staff: String?
        let name: String?
    }
    struct Report: Codable, Equatable {
        let summary: String
        let at: String?
    }
    let creator: String?
    let assignee: Assignee?
    let profile: String?
    let profileLabel: String?
    let state: String?
    let sessionId: String?
    let sessionRef: String?
    let decisionRef: String?
    let report: Report?
    let error: String?
}

/// The staff the owner can hand a task to, in the owner's own order. The
/// Bridge stores the `LAAStaff` raw value ("monet", "cfo", …).
enum LAATaskStaff {
    static let assignable: [LAAStaff] = [.monet, .argus, .cfo, .cio, .cos, .cso, .cto]

    static func name(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return LAAStaff(rawValue: raw)?.name ?? raw
    }
}

/// The list's one filter. Every row comes from the owner's own range; the
/// Bridge's run record is what tells a task the owner created from one an
/// agent registered for the owner.
enum LAALinearTaskFilter: String, CaseIterable, Identifiable {
    case related, created, assigned
    static let storageKey = "laa.work.taskFilter"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .related: LAATaskRunCopy.filterRelated
        case .created: LAATaskRunCopy.filterCreated
        case .assigned: LAATaskRunCopy.filterAssigned
        }
    }
    /// The created filter needs a run record; an older Bridge (no `run`) keeps
    /// every row under 自分が担当, as it reads today.
    func matches(_ task: LAALinearTask) -> Bool {
        switch self {
        case .related: true
        case .created: task.run != nil
        case .assigned: task.run == nil || task.run?.assignee?.kind != "staff"
        }
    }
}

/// What a row shows for the execution record: the contract's Japanese label,
/// the colour the status asks for, and the session a tap opens.
struct LAATaskRunStatus: Equatable {
    enum Tone { case quiet, attention, link }
    let label: String
    let tone: Tone
    let sessionID: String?

    var color: Color {
        switch tone {
        case .quiet: LAAColor.secondaryText
        case .attention: LAAColor.attention
        case .link: LAAColor.link
        }
    }
}

enum LAATaskRunCopy {
    static let filterRelated = "自分に関係"
    static let filterCreated = "自分が作成"
    static let filterAssigned = "自分が担当"
    static let runningReason = "実施中のため、終わってから完了できます"

    ///「完了にしますか？」の本文。The session line is added only when the task
    /// has one; the number is the one the owner says ("S5").
    static func completionMessage(for task: LAALinearTask) -> String {
        var message = "一覧から消し、記録をHQに保管します。"
        guard task.run?.sessionId != nil else { return message }
        if let ref = task.run?.sessionRef, !ref.isEmpty {
            message += "セッション（\(ref)）はアーカイブします。"
        } else {
            message += "セッションはアーカイブします。"
        }
        return message
    }

    /// The picked tasks' confirmation, asked only when one of them has a
    /// session to archive: 「選択した3件を完了にしますか？」.
    static func batchTitle(count: Int) -> String { "選択した\(count)件を完了にしますか？" }
    /// The batch bar's button, and its words while the batch is sent.
    static func batchButton(count: Int) -> String { "選択した\(count)件を完了にする" }
    static func batchProgress(done: Int, total: Int) -> String { "完了にしています（\(done)/\(total)）" }

    static func batchMessage(for tasks: [LAALinearTask]) -> String {
        var message = "一覧から消し、記録をHQに保管します。"
        let sessions = tasks.filter { $0.run?.sessionId != nil }
        guard !sessions.isEmpty else { return message }
        let refs = sessions.compactMap { $0.run?.sessionRef }.filter { !$0.isEmpty }
        if refs.count == sessions.count {
            message += "セッション（\(refs.joined(separator: "・"))）はアーカイブします。"
        } else {
            message += "セッション\(sessions.count)件はアーカイブします。"
        }
        return message
    }

    /// What is left on screen after a batch that did not finish every task.
    static func batchFailure(completed: Int, failed: [(LAALinearTask, String)], unknown: LAALinearTask?) -> String? {
        if let unknown {
            let name = LAATaskNumberLabel.number(unknown) ?? unknown.title
            return "\(completed)件を完了しました。\(name)の結果を確認できないため、残りは止めました。接続を確認して、もう一度お試しください。"
        }
        guard let first = failed.first else { return nil }
        let name = LAATaskNumberLabel.number(first.0) ?? first.0.title
        let others = failed.count > 1 ? "ほか\(failed.count - 1)件" : ""
        return "\(completed)件を完了しました。\(name)\(others)は完了できませんでした：\(first.1)"
    }
}

extension LAALinearTask {
    /// 担当: the owner unless the Bridge's run names a staff member.
    var assigneeDisplay: String {
        guard let run else { return "社長" }
        if let name = run.assignee?.name, !name.isEmpty { return name }
        if run.assignee?.kind == "staff" {
            return LAATaskStaff.name(run.assignee?.staff) ?? run.assignee?.staff ?? "AI"
        }
        return "社長"
    }

    /// Nil for the owner's own tasks (担当 社長): no badge.
    var runStatus: LAATaskRunStatus? {
        guard let run, let state = run.state, !state.isEmpty else { return nil }
        let base: String
        switch state {
        case "queued": base = "取得待ち"
        case "running": base = "実施中"
        case "awaiting_decision": base = "判断待"
        case "done": base = "完了"
        case "stopped": base = "停止"
        case "failed": base = "取得できません"
        default: base = state
        }
        let suffix = run.sessionRef.flatMap { $0.isEmpty ? nil : "（\($0)）" } ?? ""
        let tone: LAATaskRunStatus.Tone
        switch state {
        case "awaiting_decision", "stopped", "failed": tone = .attention
        case "done": tone = .link
        default: tone = .quiet
        }
        return LAATaskRunStatus(label: base + suffix, tone: tone,
                                sessionID: run.sessionId.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A staff member is still working on it: the list refreshes while one exists.
    var isAgentActive: Bool {
        guard let state = run?.state else { return false }
        return ["queued", "running", "awaiting_decision"].contains(state)
    }

    /// Running sessions keep the record open; everything else may be completed.
    var completionBlockedReason: String? {
        run?.state == "running" ? LAATaskRunCopy.runningReason : nil
    }
}

/// The create request body (contract 2026-11-09). Assignee is explicit; a
/// staff assignee must carry the profile the Bridge starts it with.
enum LAALinearTaskCreate {
    static func body(id: String, title: String, description: String, priority: Int,
                     dueDate: String?, staff: String?, profile: String?) -> Data? {
        let due: Any = dueDate.map { $0 as Any } ?? NSNull()
        var body: [String: Any] = ["id": id, "title": title, "description": description,
                                   "priority": priority, "dueDate": due]
        if let staff, !staff.isEmpty {
            guard let profile, !profile.isEmpty, profile.count <= 100 else { return nil }
            body["assignee"] = ["kind": "staff", "staff": staff]
            body["profile"] = profile
        } else {
            body["assignee"] = ["kind": "owner"]
        }
        return try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }

    /// 「Monetが取得して、完了まで進めます。」 for an AI assignee, nil for 社長.
    static func footer(staff: String?) -> String? {
        guard let name = LAATaskStaff.name(staff) else { return nil }
        return "\(name)が取得して、完了まで進めます。"
    }

    /// A device without `sessions:write` may still keep its own tasks; only
    /// handing one to a staff member is refused (Bridge 403
    /// `insufficient_scope`). The owner keeps the form and its text.
    static let insufficientScopeMessage = "この端末からはAI社員に任せられません。担当を自分にするか、iPhoneから作成してください。"

    static func hasStaffAssignee(_ body: Data?) -> Bool {
        guard let body, let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let assignee = fields["assignee"] as? [String: Any] else { return false }
        return assignee["kind"] as? String == "staff"
    }

    /// The create form's own words for a confirmed refusal, or nil for any
    /// other failure (which keeps the list's existing message).
    static func refusalMessage(status: Int, code: String?, body: Data?) -> String? {
        guard status == 403, code == "insufficient_scope", hasStaffAssignee(body) else { return nil }
        return insufficientScopeMessage
    }
}

/// `POST /v1/linear-owner-tasks/{id}/complete` on the existing draft store: the
/// request stays on the device while the outcome is unknown, and a repeat
/// carries the same idempotency key so the Bridge replays instead of finishing
/// twice.
@MainActor
enum LAALinearTaskCompletion {
    enum Outcome: Equatable {
        case completed
        /// Nothing changed (a refusal the Bridge confirmed).
        case failed(String)
        /// The request is still on the device; the owner can retry the same key.
        case unknown
    }

    private struct Response: Decodable {
        let id: String
        let completed: Bool
        let sessionArchived: Bool?
        let archive: String?
    }

    static func complete(_ task: LAALinearTask, bridge: LAABridgeSession,
                         drafts: ComposerDraftStore, key: ComposerDraftKey) async -> Outcome {
        guard let device = bridge.deviceID else { return .failed("端末が接続されていません。") }
        let mutation = LAALinearTaskMutation(method: "POST", id: task.id, body: nil,
                                             version: task.updatedAt, action: "complete")
        guard mutation.isValid else { return .failed("完了の内容を送れません。読み直してください。") }
        let item: ComposerDraftStore.Submission
        if let pending = LAAWorkDrafts.pending(drafts, key: key) {
            guard LAAWorkDrafts.canRepeat(pending) else { return .failed(LAAWorkDrafts.expiredMessage) }
            // The detail does not see the list's pending write; do not reuse
            // an edit or an archive as if it were this completion.
            if let (bytes, _) = LAAWorkDrafts.request(pending),
               let stored = try? JSONDecoder().decode(LAALinearTaskMutation.self, from: bytes),
               stored.action != "complete" || stored.id.lowercased() != task.id.lowercased() {
                // Nor another task's completion: repeating its key would
                // finish that task, not this one.
                return .failed("前の変更の結果を確認してから完了してください。")
            }
            item = pending
        } else {
            guard let data = try? JSONEncoder().encode(mutation),
                  let reserved = LAAWorkDrafts.reserve(drafts, key: key, text: "タスクの完了", body: data,
                                                       idempotency: LAABridgeIdempotencyKey()) else {
                return .failed("入力を端末に保存できません。もう一度お試しください。")
            }
            drafts.markSubmissionUnknown(reserved.id)
            item = reserved
        }
        return await send(item, bridge: bridge, drafts: drafts, device: device)
    }

    struct BatchResult: Equatable {
        var completed: [String] = []
        /// Refusals the Bridge confirmed: nothing changed for these.
        var failed: [String: String] = [:]
        /// The task whose outcome is unknown; the batch stopped there, so its
        /// request stays on the device and the rest were not sent.
        var unknown: String?
        /// Not sent because an earlier outcome was unknown.
        var skipped: [String] = []
    }

    /// The picked tasks, one after another on the same protected path. A
    /// refusal is kept and the next one goes on; an unknown outcome stops the
    /// batch, because the next request would find this one still on the
    /// device. `each` reports every outcome as it lands, so a row leaves the
    /// list the moment its own completion is confirmed.
    static func completeAll(_ tasks: [LAALinearTask], bridge: LAABridgeSession, drafts: ComposerDraftStore,
                            key: ComposerDraftKey,
                            each: (LAALinearTask, Outcome) -> Void = { _, _ in }) async -> BatchResult {
        var result = BatchResult()
        for (index, task) in tasks.enumerated() {
            if Task.isCancelled { result.skipped = tasks[index...].map(\.id); break }
            let outcome = await complete(task, bridge: bridge, drafts: drafts, key: key)
            each(task, outcome)
            switch outcome {
            case .completed: result.completed.append(task.id)
            case .failed(let message): result.failed[task.id] = message
            case .unknown:
                result.unknown = task.id
                result.skipped = tasks[(index + 1)...].map(\.id)
                return result
            }
        }
        return result
    }

    /// Repeats the request already on the device with its own key, so the
    /// Bridge replays instead of finishing twice.
    static func send(_ item: ComposerDraftStore.Submission, bridge: LAABridgeSession,
                     drafts: ComposerDraftStore, device: String? = nil) async -> Outcome {
        let device = device ?? bridge.deviceID
        guard let device else { return .unknown }
        guard LAAWorkDrafts.canRepeat(item), let (bytes, token) = LAAWorkDrafts.request(item),
              let stored = try? JSONDecoder().decode(LAALinearTaskMutation.self, from: bytes),
              stored.isValid, stored.action == "complete", stored.method == "POST" else {
            return .failed(LAAWorkDrafts.expiredMessage)
        }
        do {
            let result: LAABridgeResponse<Response> = try await bridge.request(
                method: stored.method, path: stored.path, idempotencyKey: token, ifMatch: stored.version)
            guard bridge.deviceID == device else { return .unknown }
            guard result.data.id.lowercased() == stored.id.lowercased(), result.data.completed else {
                return .failed("完了を受け付けられませんでした。読み直してからお試しください。")
            }
            guard drafts.finishSubmission(item.id, restoring: false) else {
                return .failed("完了しましたが、端末の控えを更新できません。再確認してください。")
            }
            return .completed
        } catch let error as LAABridgeHTTPError {
            guard bridge.deviceID == device else { return .unknown }
            if error.status == 409 && error.code == "session_running" {
                _ = drafts.finishSubmission(item.id, restoring: false)
                return .failed("実施中のため完了できません。")
            }
            if error.status == 403 && error.code == "insufficient_scope" {
                _ = drafts.finishSubmission(item.id, restoring: false)
                return .failed("この端末からはAI社員のタスクを完了できません。iPhoneから完了してください。")
            }
            if [400, 403, 404, 412, 422, 428].contains(error.status) {
                _ = drafts.finishSubmission(item.id, restoring: false)
                if error.status == 412 {
                    return .failed("Linearで更新されています。読み直してから完了してください。")
                }
                return .failed("完了が受け付けられませんでした。接続を確認してください。")
            }
            return .unknown
        } catch {
            return .unknown
        }
    }
}
#endif
