#if LAA_BUILD
import Foundation

/// Decode machine fields only. In particular, neither gateway prose nor
/// assistant content is searched for failure markers.
enum HermesChatFailure {
    static func terminal(type: String, payload: [String: AnyCodable]) -> ChatRuntimeFailure? {
        switch type {
        case "message.interrupted", "session.interrupted": return failure(payload, fallback: .interrupted)
        case "error": return failure(payload)
        case "message.complete":
            switch payload["status"]?.stringValue {
            case "interrupted", "cancelled": return failure(payload, fallback: .interrupted)
            case "error", "failed": return failure(payload)
            default:
                if payload["error"]?.stringValue?.isEmpty == false || payload["error"]?.objectValue != nil {
                    return failure(payload)
                }
                return nil
            }
        default: return nil
        }
    }

    static func failure(_ error: Error) -> ChatRuntimeFailure {
        if let error = error as? ChatRuntimeFailure { return error }
        if let error = error as? RpcError {
            var fields = error.chatFailureFields
            if let reason = error.reason { fields["reason"] = .string(reason) }
            if let code = error.code { fields["code"] = .number(Double(code)) }
            return failure(fields)
        }
        if let error = error as? HermesError {
            switch error {
            case .timeout: return .init(.timeout)
            case .connectionClosed, .notConnected, .invalidUrl: return .init(.runtimeUnavailable)
            case .steerRejected: return .init(.rejected)
            case .invalidResponse: return .init(.internal)
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return .init(.timeout)
            case .cancelled: return .init(.interrupted)
            default: return .init(.runtimeUnavailable)
            }
        }
        return .init(error is CancellationError ? .interrupted : .internal)
    }

    static func failure(_ payload: [String: AnyCodable], fallback: ChatRuntimeFailure.Code = .internal) -> ChatRuntimeFailure {
        let nested = ["error", "data", "billing", "quota"].compactMap { payload[$0]?.objectValue }
        let fields = [payload] + nested
        let retryAt = fields.lazy.compactMap {
            parseDate($0["retry_at"] ?? $0["retry_at_ms"] ?? $0["reset_at"] ?? $0["resets_at"])
        }.first
        if fields.contains(where: { $0["quota_exhausted"]?.boolValue == true })
            || payload["quota"]?.objectValue?["exhausted"]?.boolValue == true {
            return .init(.quotaExhausted, retryAt: retryAt)
        }
        for key in ["failure_class", "provider_failure_class", "error_type", "failure_reason", "reason", "code", "type", "status"] {
            for input in fields {
                if let raw = input[key]?.stringValue?.lowercased(), let code = CodeMap.string(raw) {
                    return .init(code, retryAt: retryAt)
                }
            }
        }
        for input in fields {
            if let raw = input["code"]?.intValue ?? input["status_code"]?.intValue, let code = CodeMap.number(raw) {
                return .init(code, retryAt: retryAt)
            }
        }
        return .init(fallback, retryAt: retryAt)
    }

    private static func parseDate(_ value: AnyCodable?) -> Date? {
        if let raw = value?.doubleValue, raw.isFinite, raw > 0 {
            return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1_000 : raw)
        }
        guard let raw = value?.stringValue else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: raw)
    }

    private enum CodeMap {
        static func string(_ raw: String) -> ChatRuntimeFailure.Code? {
            if let code = ChatRuntimeFailure.Code(rawValue: raw) { return code }
            switch raw {
            case "rate_limit", "rate_limited", "quota", "insufficient_quota", "resource_exhausted", "billing_blocked", "credits_exhausted": return .quotaExhausted
            case "model_not_found", "unsupported_model", "model_access_denied", "model_error": return .modelUnavailable
            case "cancelled", "canceled", "interruption", "keyboardinterrupt": return .interrupted
            case "request_timeout", "deadline_exceeded", "timeouterror", "apitimeouterror": return .timeout
            case "context_length_exceeded", "context_window_exceeded", "prompt_too_long", "context_overflow_error": return .contextOverflow
            case "tool_error", "tool_execution_failed": return .toolFailed
            case "connection_error", "service_unavailable", "session_not_found", "provider_unavailable", "overloaded": return .runtimeUnavailable
            case "busy", "session_busy", "session_not_owned", "steer_rejected", "invalid_params": return .rejected
            default: return nil
            }
        }

        static func number(_ raw: Int) -> ChatRuntimeFailure.Code? {
            switch raw {
            case 402, 429: return .quotaExhausted
            case 408, 504: return .timeout
            case -32602, 4000, 4009, 4090: return .rejected
            case 4001, 4007, 502, 503: return .runtimeUnavailable
            default: return nil
            }
        }
    }
}
#endif
