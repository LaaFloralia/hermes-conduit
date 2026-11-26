#if LAA_BUILD
import SwiftUI

@MainActor
final class LAAMeetingSession: ObservableObject {
    let endpoint = LAAMeetingEndpoint()
    @Published private(set) var turn = LAAMeetingTurn()
    @Published var claiming = false
    @Published var note: String?
    @Published var speechLevel: Double = 0
    @Published var micLevel: Double = 0
    private var vad = LAAMeetingVAD()
    private var captureStarted: ContinuousClock.Instant?
    @Published private(set) var captions: [String] = []
    @Published private(set) var revision = 0
    private(set) var roundID: String?
    private var lastTicket: UInt64?
    private var closeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    var onTimeout: (() -> Void)?

    func observeMic(_ rms: Double) -> Bool {
        guard turn.ownerTalking, let captureStarted else { return false }
        micLevel = min(1, rms * 8)
        #if targetEnvironment(macCatalyst)
        return false // Hold Space is the capture boundary on Mac.
        #else
        return vad.observe(level: rms, at: captureStarted.duration(to: ContinuousClock().now))
        #endif
    }

    func apply(_ event: LAAMeetingTurn.Event) {
        turn.apply(event)
        switch event {
        case .tapTalk, .bargeIn:
            captureStarted = ContinuousClock().now
            vad = LAAMeetingVAD()
        case .vadEnd, .leave:
            captureStarted = nil
            micLevel = 0
        default: break
        }
        switch event {
        case .join, .tapTalk, .bargeIn, .leave, .roundClosed, .timeout:
            roundID = nil
            closeTask?.cancel()
            closeTask = nil
            timeoutTask?.cancel()
            timeoutTask = nil
        case .sendRegistered:
            startTimeout()
        default: break
        }
        if case .leave = event {
            captions = []
            lastTicket = nil
            closeTask?.cancel()
            closeTask = nil
        }
    }

    func registerRound(_ eventID: String) {
        guard turn.phase != .idle, !turn.ownerTalking else { return }
        closeTask?.cancel()
        closeTask = nil
        roundID = eventID
        apply(.sendRegistered)
    }

    func update(_ queue: LAAChairedVoicePlayback, memberRunning: Bool) {
        guard queue.phase != .silent else { return }
        revision &+= 1
        if let playing = queue.current, lastTicket != playing.ticket {
            let total = queue.queue.count + 1
            if lastTicket != nil { apply(.ttsFinished(remaining: total)) }
            let line = LAAMeetingTurn.spokenExcerpt(SpokenTextFilter.filter(playing.utterance.text))
            if !line.isEmpty { captions = Array((captions + [line]).suffix(2)) }
            lastTicket = playing.ticket
            apply(.messageComplete(total: total))
            startTimeout()
        } else if queue.current == nil, lastTicket != nil {
            lastTicket = nil
            if queue.phase == .engaged { apply(.ttsFinished(remaining: 0)); startTimeout() }
        } else if queue.current != nil {
            apply(.messageComplete(total: queue.queue.count + 1))
        }
        if memberRunning || queue.current != nil || !queue.queue.isEmpty || queue.phase == .ownerTalking {
            closeTask?.cancel()
            closeTask = nil
        } else if lastTicket == nil, turn.phase == .waiting, closeTask == nil {
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1_500))
                guard !Task.isCancelled, let self else { return }
                self.closeTask = nil
                self.apply(.roundClosed)
            }
        }
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(75))
            guard !Task.isCancelled, let self else { return }
            self.onTimeout?()
            self.apply(.timeout)
        }
    }
}
#endif
