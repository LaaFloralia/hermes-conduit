#if LAA_BUILD
import Foundation

/// Work-specific policy around the shared Bridge client. Transport, credentials,
/// response decoding and retries remain owned by LAABridgeSession.
enum LAAWorkHTTP {
    @MainActor static func write<T: Decodable>(_ bridge: LAABridgeSession, path: String,
                                               body: Data, key: LAABridgeIdempotencyKey,
                                               method: String = "POST", etag: String? = nil) async throws -> T {
        let response: LAABridgeResponse<T> = try await bridge.request(
            method: method, path: path, jsonBody: body, idempotencyKey: key, ifMatch: etag, timeout: 90)
        return response.data
    }

    @MainActor static func projectWrite(bridge: LAABridgeSession, id: String?, body: Data,
                                        key: LAABridgeIdempotencyKey, etag: String?) async throws -> LAAWorkProject {
        if let id {
            guard let etag else { throw LAABridgeError.invalidResponse }
            return try await write(bridge, path: "/v1/projects/\(id)", body: body, key: key, method: "PATCH", etag: etag)
        }
        return try await write(bridge, path: "/v1/projects", body: body, key: key)
    }

    static func isVersionConflict(_ error: LAABridgeHTTPError) -> Bool { error.status == 412 }

    /// A received refusal can restore the draft only when the Bridge confirms
    /// the operation did not run. Delivery and idempotency uncertainty must
    /// keep the original request and key available for reconciliation.
    static func outcomeUnknown(_ error: LAABridgeHTTPError) -> Bool {
        let ambiguous: Set<String> = ["idempotency_key_in_flight", "idempotency_outcome_unknown",
            "idempotency_key_conflict", "request_id_conflict", "creation_outcome_unknown",
            "send_outcome_unknown", "message_id_conflict", "model_effort_mismatch"]
        if let code = error.code, ambiguous.contains(code) { return true }
        return !(400..<500).contains(error.status)
    }

    static func message(_ error: LAABridgeHTTPError) -> String {
        switch error.code {
        case "pending_decision_requires_reply": return "判断待ちのため追加送信できません。判断内容を確認してください。"
        case "session_stopped": return "停止済みまたは停止確認中です。停止が確認できた後、後継セッションを開始できます。"
        case "session_busy": return "セッションは実行中です。完了してから追加指示を送れます。"
        case "message_limit_reached": return "このセッションは追加指示の上限に達しました。"
        case "message_id_conflict": return "送信IDが別の内容と衝突しました。ログと送信状況を確認してください。"
        case "model_effort_mismatch": return "要求したモデル・推論設定と実際の状態が一致しません。実行状況を確認してください。"
        case "session_not_stopped": return "停止を確認できていないため再開できません。"
        case "stop_unconfirmed": return "停止要求は届きましたが、停止を確認できていません。"
        case "idempotency_key_in_flight": return "前の要求は処理中です。状態を確認してください。"
        case "idempotency_outcome_unknown", "creation_outcome_unknown", "send_outcome_unknown":
            return "前の要求の結果を確認できません。同じIDの状態を確認してください。"
        case "profile_unsupported": return "このプロファイルは利用できません。名前を確認してください。"
        case "request_id_conflict", "idempotency_key_conflict": return "要求IDが別の内容と衝突しました。状態を確認してください。"
        default: return error.legacyError.japaneseText
        }
    }
}
#endif
