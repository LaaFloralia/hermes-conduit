#if LAA_BUILD
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// The two Chat crashes the owner reported (2026-11-14 21:49 and 2026-11-15
/// 07:59) followed the same order on the Mac mini's Hermes: a terminal tool
/// finished in a long conversation (~240 rows) during a thinking turn, and
/// context compression started at once (`status.update` kind `compacting`).
/// The app's socket closed 2.5–16 s later. This runs the real ChatView
/// through that order and keeps it on screen long enough to fail the same way.
@MainActor
final class LAAChatCompactionCrashTests: XCTestCase {
    private var window: UIWindow?
    private var host: UIViewController?
    private var appState: AppState?

    override func tearDown() {
        appState?.setStreamingTextForTesting("")
        if let window {
            window.isHidden = true
            window.rootViewController = nil
            host?.view.removeFromSuperview()
            pump(host?.view, seconds: 0.5)
        }
        window = nil
        host = nil
        appState = nil
        super.tearDown()
    }

    /// Rows like the owner's: Japanese prose with blank lines, lists, code,
    /// tool rows with long output, every few turns.
    private static func transcript(_ count: Int) -> [ChatMessage] {
        (0..<count).map { index in
            let stamp = String(format: "2026-11-14T12:%02d:%02dZ", (index / 60) % 60, index % 60)
            switch index % 6 {
            case 0:
                return ChatMessage(id: "row-\(index)", role: .user,
                                   content: "依頼 \(index)。\n\nこの件を確認して、終わったら報告してください。\n改行も含みます。",
                                   timestamp: stamp)
            case 1:
                return ChatMessage(id: "row-\(index)", role: .assistant,
                                   content: "告。\(index)件目の結果です。\n\n| 項目 | 状態 |\n|---|---|\n| A | 済 |\n| B | 未 |\n\n- 一点目\n- 二点目\n\n```sh\nls -la /Users/laa\n```",
                                   timestamp: stamp)
            case 2:
                return ChatMessage(id: "row-\(index)", role: .tool, content: "", timestamp: stamp,
                                   tool: ToolActivity(id: "call-\(index)", name: "terminal",
                                                      input: "grep -rn foo /Users/laa/dev",
                                                      output: String(repeating: "line of output \(index)\n", count: 80),
                                                      status: .complete))
            default:
                return ChatMessage(id: "row-\(index)", role: .assistant,
                                   content: String(repeating: "長めの本文です。これは\(index)番目の段落で、読みやすさを確かめます。", count: 6),
                                   timestamp: stamp)
            }
        }
    }

    private func pump(_ view: UIView?, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            view?.setNeedsLayout()
            view?.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
        }
    }

    private func mount(rows: Int) throws -> (AppState, UIViewController) {
        let suiteName = "laa-chat-compaction-crash"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.activeSessionId = "monet"
        appState.messages = Self.transcript(rows)
        let host = UIHostingController(
            rootView: DormancyHarnessEnvironment.applying(
                ChatView(chatTextSizeOverride: DormancyHarnessEnvironment.pinnedChatTextSize)
                    .environmentObject(appState)
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        self.host = host
        self.appState = appState
        pump(host.view, seconds: 1.0)
        return (appState, host)
    }

    func testToolThenCompactionDuringAThinkingTurnKeepsTheChatAlive() throws {
        let (appState, host) = try mount(rows: 240)
        let sid = "monet"
        appState.handleStreamEvent(.sessionBusy(sessionId: sid, busy: true))
        appState.handleStreamEvent(.messageStart(sessionId: sid))
        for chunk in 0..<40 {
            appState.handleStreamEvent(.reasoningDelta(sessionId: sid, text: "考えています \(chunk)。\n"))
            pump(host.view, seconds: 0.03)
        }
        appState.handleStreamEvent(.toolStart(sessionId: sid, toolName: "terminal",
                                              toolInput: "cat /Users/laa/work/report.md", toolID: "call-live"))
        pump(host.view, seconds: 0.5)
        appState.handleStreamEvent(.toolComplete(sessionId: sid, toolName: "terminal",
                                                 toolOutput: String(repeating: "結果の行です。\n", count: 140),
                                                 toolID: "call-live"))
        appState.handleStreamEvent(.statusUpdate(sessionId: sid, kind: .compacting,
                                                 text: "🗜️ Compacting context (~200,954 tokens)…"))
        // The crashes came 2.5–16 s after this edge.
        pump(host.view, seconds: 16)
        for chunk in 0..<20 {
            appState.handleStreamEvent(.messageDelta(sessionId: sid, text: "続きの本文 \(chunk)。\n"))
            pump(host.view, seconds: 0.05)
        }
        appState.handleStreamEvent(.statusUpdate(sessionId: sid, kind: .compacted, text: "✓ Context compression complete"))
        pump(host.view, seconds: 3)
        XCTAssertFalse(appState.messages.isEmpty)
    }
}
#endif
