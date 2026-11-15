#if LAA_BUILD
import CryptoKit
import Foundation

/// Positive evidence only. A missing endpoint or an empty archive cannot prove
/// non-delivery, and must never authorize restoring or resending the words.
enum LAAArchivedUnknownDelivery {
    static func contentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func path(sessionID: String, profile: String, text: String, reservedAt: Date) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reservedAt.timeIntervalSince1970.isFinite,
              let session = DashboardPath.encodedQueryComponent(sessionID) else { return nil }
        return DashboardPath.withExplicitProfile(
            "/api/sessions/\(session)/history-window/delivery"
                + "?content_sha256=\(contentHash(text))&reserved_at=\(reservedAt.timeIntervalSince1970)",
            profile: profile
        )
    }

    static func landed(_ payload: [String: Any], sessionID: String, profile: String,
                       text: String, reservedAt: Date) -> Bool {
        guard payload["session_id"] as? String == sessionID,
              payload["profile"] as? String == profile,
              payload["status"] as? String == "matched",
              let matches = payload["matches"] as? [[String: Any]], matches.count == 1,
              let row = matches.first, row["role"] as? String == "user",
              row["content_sha256"] as? String == contentHash(text),
              let timestamp = row["timestamp"] as? Double, timestamp.isFinite else { return false }
        // Repeated short messages in a different turn are not delivery proof.
        return abs(timestamp - reservedAt.timeIntervalSince1970) <= LAAUnknownDelivery.clockSkew
    }
}
#endif
