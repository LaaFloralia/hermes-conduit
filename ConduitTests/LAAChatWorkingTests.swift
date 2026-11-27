#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// The floating working control and the subagent cards (LAAWorkingCluster,
/// LAASubagentGroup): their states, and each drawn at 440 pt light and dark.
@MainActor
final class LAAChatWorkingTests: XCTestCase {
    private let width: CGFloat = 440
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func agent(_ id: String, _ status: DelegateAgentActivity.Status, gateway: Bool = true,
                       updated: Date? = nil, goal: String? = nil) -> DelegateAgentActivity {
        DelegateAgentActivity(id: id, goal: goal ?? "Read \(id)\nmore", model: "claude-opus-5-5", status: status,
                              taskCount: 1, taskIndex: 0, currentTool: status == .running ? "read_file" : nil,
                              summary: status == .failed ? "Timed out reading the folder." : nil, stream: [],
                              hasGatewayID: gateway, sessionId: gateway ? "s1" : "", updatedAt: updated ?? start)
    }

    // MARK: States

    func testStatusFollowsTheTurn() {
        XCTAssertNil(LAAChatWorking.status(isBusy: false, startedAt: start, toolRunning: false, agents: []), "Idle: no pill")
        let running = LAAChatWorking.status(isBusy: true, startedAt: start, toolRunning: false, agents: [])
        XCTAssertEqual(running?.word, "Thinking")
        XCTAssertEqual(running?.startedAt, start, "The timer runs from the turn's stable start")
        XCTAssertEqual(LAAChatWorking.status(isBusy: true, startedAt: start, toolRunning: true, agents: [])?.word, "Working")
    }

    func testChildrenOfTheTurn() {
        let old = agent("old", .completed, updated: start.addingTimeInterval(-60))
        let one = LAAChatWorking.status(isBusy: true, startedAt: start, toolRunning: false,
                                        agents: [old, agent("a", .running)])
        XCTAssertEqual(one?.children.map(\.id), ["a"], "A child settled before this turn is not this turn's")
        let three = LAAChatWorking.children([agent("a", .running), agent("b", .queued), agent("c", .failed, updated: start.addingTimeInterval(5))],
                                            since: start)
        XCTAssertEqual(three.map(\.state), [.running, .waiting, .failed])
        XCTAssertEqual(three[0].title, "Read a", "The goal's first line")
        XCTAssertEqual(LAAChatWorking.child(agent("untitled", .running, goal: "")).title, "Agent")
        XCTAssertEqual(three[0].meta, "Opus 5.5")
        XCTAssertEqual(three[2].preview, "Timed out reading the folder.")
        XCTAssertFalse(LAAChatWorking.child(agent("x", .running, gateway: false)).resolvable,
                       "An agent Hermes did not name cannot be opened")
    }

    func testRowShapesWordsAndColours() {
        let rows: [LAAWorkingChild] = [
            .init(id: "1", title: "Running", state: .running),
            .init(id: "2", title: "Attention", state: .attention),
            .init(id: "3", title: "Waiting", state: .waiting),
            .init(id: "4", title: "Failed", state: .failed),
        ]
        XCTAssertEqual(rows.map(\.shape), ["●", "▲", "○", "▲"])
        XCTAssertEqual(rows.map(\.word), ["実行中", "判断待ち", "待機中", "失敗"])
        XCTAssertEqual(LAAWorkingChild(id: "5", title: "Work", state: .waiting, label: "確認待ち").word, "確認待ち")
    }

    func testMetricsFollowTheControlContract() {
        #if !targetEnvironment(macCatalyst)
        XCTAssertEqual(LAAWorkingControlMetrics.pillHeight, 36)
        XCTAssertEqual(LAAWorkingControlMetrics.jumpDiameter, 36)
        XCTAssertEqual(LAAWorkingControlMetrics.jumpIcon, 20)
        #else
        XCTAssertEqual(LAAWorkingControlMetrics.pillHeight, 28 / 0.77, accuracy: 0.5)
        #endif
        XCTAssertGreaterThanOrEqual(LAAWorkingControlMetrics.hitHeight, 44)
        XCTAssertEqual(LAAWorkingControlMetrics.mergeSpacing, 12)
        XCTAssertEqual(LAAWorkingControlMetrics.enter, 0.22)
        XCTAssertEqual(LAAWorkingControlMetrics.exit, 0.12)
    }

    // MARK: Work children

    private func session(_ id: String, created: String, phase: String = "running") throws -> LAAWorkSession {
        let json: [String: Any] = [
            "id": id, "name": "Child \(id)", "nameSource": "owner", "requestId": id, "parentId": "parent",
            "workspaceId": "ws_test", "profile": "test", "requested": ["model": "claude-opus-5-5", "effort": "high"],
            "observed": NSNull(), "phase": phase, "createdAt": created, "updatedAt": created,
            "events": ["lastSeq": 1, "oldestSeq": 1, "cursor": "cursor"],
        ]
        return try JSONDecoder().decode(LAAWorkSession.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testWorkChildrenGroupByBatchAfterTheirMessage() throws {
        let children = [
            try session("a", created: "2026-11-25T01:00:10Z"),
            try session("b", created: "2026-11-25T01:00:40Z", phase: "awaiting_decision"),
            try session("c", created: "2026-11-25T01:30:00Z", phase: "error"),
        ]
        let messages = [
            LAAWorkConversationMessage(id: "m1", role: "user", text: "Go", timestamp: "2026-11-25T01:00:00Z"),
            LAAWorkConversationMessage(id: "m2", role: "assistant", text: "Spawned", timestamp: "2026-11-25T01:20:00Z"),
        ]
        let placements = LAAWorkChildren.placements(children, messages: messages)
        XCTAssertEqual(placements.map { $0.children.map(\.id) }, [["a", "b"], ["c"]])
        XCTAssertEqual(placements.map(\.afterMessageID), ["m1", "m2"])
        let rows = children.map { LAAWorkChildren.child($0, options: nil) }
        XCTAssertEqual(rows.map(\.state), [.running, .attention, .failed])
        XCTAssertEqual(rows.map(\.word), ["Running", "Decision", "Failed"])
        XCTAssertEqual(rows[0].meta, "Opus 5.5 · High")
    }

    func testWorkChildLabelsMatchTheWorkingControlVocabulary() throws {
        let cases: [(String, LAAWorkingChild.State, String)] = [
            ("running", .running, "Running"),
            ("awaiting_decision", .attention, "Decision"),
            ("stop_unconfirmed", .attention, "Decision"),
            ("created", .waiting, "Waiting"),
            ("awaiting_review", .waiting, "Waiting"),
            ("idle", .waiting, "Waiting"),
            ("error", .failed, "Failed"),
            ("closed", .done, "Done"),
            ("stopped", .done, "Done"),
        ]
        for (phase, state, word) in cases {
            let child = LAAWorkChildren.child(try session(phase, created: "2026-11-25T01:00:10Z", phase: phase), options: nil)
            XCTAssertEqual(child.state, state, phase)
            XCTAssertEqual(child.word, word, phase)
        }
        XCTAssertEqual(LAAWorkPresentation.compacting, "Compacting")
    }

    // MARK: Drawn

    func testWorkingControlStatesAreDrawn() throws {
        let one = [LAAWorkingChild(id: "a", title: "Read the folder", state: .running, meta: "Opus 5.5 · High", startedAt: start)]
        let three = one + [
            LAAWorkingChild(id: "b", title: "Check the build", state: .attention, meta: "GPT 6.2 Sol · High"),
            LAAWorkingChild(id: "c", title: "Write the notes", state: .waiting),
        ]
        let states: [(String, LAAWorkingStatus?, Bool)] = [
            ("idle", nil, false),
            ("running", LAAWorkingStatus(word: "Thinking", startedAt: Date().addingTimeInterval(-42)), false),
            ("one-child", LAAWorkingStatus(word: "作業中", startedAt: Date().addingTimeInterval(-42), orb: .tool, children: one), false),
            ("three-children", LAAWorkingStatus(word: "作業中", startedAt: Date().addingTimeInterval(-42), orb: .tool, children: three), false),
            ("scrolled-up", LAAWorkingStatus(word: "Thinking", startedAt: Date().addingTimeInterval(-42)), true),
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (name, status, jump) in states {
                let image = try render(style: style, height: 180) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        LAAWorkingCluster(status: status, showsJump: jump, jump: {}, openChildren: {}) {
                            RoundedRectangle(cornerRadius: 22).fill(LAAColor.surface).frame(height: 52)
                                .padding(.horizontal, 20)
                        }
                        .padding(.bottom, 12)
                    }
                }
                let ink = differs(image, fromRowsAbove: 112, paper: color(LAAColor.background, style))
                XCTAssertEqual(ink, status != nil || jump, "\(name): the floating row draws only while it has something to say")
                attach(image, name: "working-\(name)-\(style == .dark ? "dark" : "light")")
            }
        }
    }

    func testSubagentGroupRowsAreDrawn() throws {
        let rows: [LAAWorkingChild] = [
            .init(id: "1", title: "Read the folder", state: .running, meta: "Opus 5.5 · High", startedAt: Date().addingTimeInterval(-95)),
            .init(id: "2", title: "Check the build", state: .attention, meta: "GPT 6.2 Sol · High"),
            .init(id: "3", title: "Write the notes", state: .waiting, meta: "Gemini 4 Neon"),
            .init(id: "4", title: "Render the page", state: .failed, meta: "Opus 5.5 · High",
                  preview: "Timed out after 10 minutes while rendering the page."),
            .init(id: "5", title: "An agent the app cannot open", state: .running, resolvable: false),
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            let image = try render(style: style, height: 460) {
                LAASubagentGroup(children: rows, open: { _ in }).padding(.horizontal, 20).padding(.top, 20)
            }
            attach(image, name: "subagents-\(style == .dark ? "dark" : "light")")
        }
    }

    // MARK: Rendering

    private func render<V: View>(style: UIUserInterfaceStyle, height: CGFloat, @ViewBuilder _ content: () -> V) throws -> UIImage {
        let root = content()
            .frame(width: width, height: height, alignment: .top)
            .background(LAAColor.background)
            .environment(\.colorScheme, style == .dark ? .dark : .light)
        let host = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<8 {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func color(_ color: Color, _ style: UIUserInterfaceStyle) -> [Int] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b].map { Int(($0 * 255).rounded()) }
    }

    /// Whether anything but the paper is drawn above `limit` points (the
    /// floating row's band above the composer).
    private func differs(_ image: UIImage, fromRowsAbove limit: CGFloat, paper: [Int]) -> Bool {
        let cg = image.cgImage!
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let scale = CGFloat(w) / width
        let bottom = Int(limit * scale)
        var count = 0
        for y in 0..<min(bottom, h) {
            for x in 0..<w {
                let o = (y * w + x) * 4
                if (0..<3).contains(where: { abs(Int(bytes[o + $0]) - paper[$0]) > 12 }) { count += 1 }
            }
        }
        return count > 40
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
