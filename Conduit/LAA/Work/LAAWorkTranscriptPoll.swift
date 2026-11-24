#if LAA_BUILD
import Foundation

/// Schedule only. The view's task owns cancellation; its event long-poll is
/// the change signal and bypasses the deadline only for a new event.
struct LAAWorkTranscriptPoll {
    enum Trigger { case heartbeat, changed, user }
    enum Outcome { case success, unavailable, stopped }

    private let now: () -> TimeInterval
    private let jitter: () -> Double
    private var deadline: TimeInterval = 0
    private var failures = 0
    private(set) var isStopped = false

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         jitter: @escaping () -> Double = { Double.random(in: 0.85...1.15) }) {
        self.now = now
        self.jitter = jitter
    }

    func allows(_ trigger: Trigger) -> Bool {
        guard !isStopped else { return trigger == .user }
        return trigger != .heartbeat || !(now() < deadline)
    }

    mutating func complete(_ outcome: Outcome) {
        switch outcome {
        case .stopped:
            isStopped = true
        case .success:
            isStopped = false
            failures = 0
            deadline = now() + 5
        case .unavailable:
            failures = min(failures + 1, 4)
            let delay = min(60, 5 * Double(1 << failures))
            deadline = now() + min(60, delay * jitter())
        }
    }
}
#endif
