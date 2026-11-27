#if LAA_BUILD
import Foundation

extension LAACopy {
    static let chatThinking = "Thinking"
}

/// The pending envelope's UUID survives the preview → live admission.
/// Legacy Hermes has no prompt idempotency parameter; the journal and
/// unknown-delivery probe remain authoritative on that transport.
enum LAAChatTurnIdentity {
    @TaskLocal static var pendingID: UUID?
}
#endif
