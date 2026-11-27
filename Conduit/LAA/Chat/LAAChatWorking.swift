#if LAA_BUILD
import SwiftUI

/// Chat's side of the working control: what the pill says while a turn runs,
/// built from what the chat already knows (the turn state, its start, the
/// running tool, the delegate agents Hermes reports for this conversation).
@MainActor
enum LAAChatWorking {
    /// What Chat says while a reply runs and no tool is running, for a
    /// profile with no words of its own (unknown, or none read yet).
    static let thinking = LAAStaffThinking.fallback
    /// While a tool runs, whoever answers (never mixed with an employee's words).
    static let toolRunning = "Working"

    /// The pill's state. With no tool running an employee's chat says that
    /// employee's word for this wait (LAAStaffThinking, D-01 2026-11-26),
    /// the same one through the whole wait; a tool running says Working.
    static func status(isBusy: Bool, startedAt: Date?, toolRunning: Bool,
                       agents: [DelegateAgentActivity], profile: String? = nil,
                       words: LAAStaffThinking = .shared) -> LAAWorkingStatus? {
        guard isBusy else { return nil }
        let word: String
        if toolRunning {
            word = Self.toolRunning
        } else if let profile {
            word = words.word(profile: profile)
        } else {
            word = thinking
        }
        return LAAWorkingStatus(word: word, startedAt: startedAt, orb: toolRunning ? .tool : .thinking,
                                children: children(agents, since: startedAt))
    }

    /// The transcript's typing row with no tool running: an employee's chat
    /// says the pill's word for this wait (the same hold); a chat with no
    /// words of its own keeps 考え中.
    static func rowPhrase(profile: String?, words: LAAStaffThinking = .shared) -> String {
        guard let profile, words.words(forProfile: profile) != nil else { return LAACopy.chatThinking }
        return words.word(profile: profile)
    }

    /// The turn's children: every agent still queued or running, and the
    /// ones that settled during this turn.
    static func children(_ agents: [DelegateAgentActivity], since start: Date?) -> [LAAWorkingChild] {
        agents.filter { agent in
            if agent.status.isActive { return true }
            guard let start else { return false }
            return agent.updatedAt.timeIntervalSince(start) > 0
        }
        .map(child)
    }

    static func child(_ agent: DelegateAgentActivity) -> LAAWorkingChild {
        let state: LAAWorkingChild.State
        switch agent.status {
        case .running: state = .running
        case .queued: state = .waiting
        case .failed, .interrupted: state = .failed
        case .completed: state = .done
        }
        let title = agent.goal.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let preview: String? = {
            if let summary = agent.summary, !summary.isEmpty { return summary }
            return agent.stream.last?.text
        }()
        return LAAWorkingChild(
            id: agent.id,
            title: title.isEmpty ? "Agent" : title,
            state: state,
            meta: agent.model.map(LAAWorkSessionStyle.displayModel),
            preview: state == .running ? agent.currentTool : preview,
            startedAt: nil,
            // Its live output is readable only for an agent Hermes named.
            resolvable: agent.hasGatewayID && !agent.sessionId.isEmpty
        )
    }
}

/// The chat's composer with the working pill and the jump button floating
/// above it. It observes the scroll chrome on its own, so leaving the latest
/// message redraws this cluster and not the transcript.
struct LAAChatWorkingBar<Composer: View>: View {
    @ObservedObject var chrome: ChatScrollChrome
    let status: LAAWorkingStatus?
    let jump: () -> Void
    let open: (LAAWorkingChild) -> Void
    @ViewBuilder let composer: Composer
    @State private var showingChildren = false

    var body: some View {
        LAAWorkingCluster(status: status, showsJump: chrome.inputs.showsJumpToLatest, jump: jump,
                          openChildren: openChildren, identifier: "chat.working") { composer }
            .sheet(isPresented: $showingChildren) {
                LAASubagentSheet(children: status?.children ?? [], open: { child in
                    showingChildren = false
                    open(child)
                }, done: { showingChildren = false })
            }
    }

    /// One child opens itself; two or more open the list.
    private func openChildren() {
        guard let children = status?.children, !children.isEmpty else { return }
        if children.count == 1 {
            if children[0].resolvable { open(children[0]) }
        } else {
            showingChildren = true
        }
    }
}
#endif
