#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// 440 × 956 pt light and dark captures of the decision board: the list, a
/// detail, the empty board, an answer that did not arrive, an older Mac and
/// the short "sent" moment. Attachments are exported from the result bundle.
@MainActor
final class LAADecisionSnapshotTests: XCTestCase {
    private func iso(_ hours: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(hours * 3600))
    }

    private var items: [LAADecision] {
        [
            LAADecision(id: "dec_0000000000000a01", title: "HPの公開日を決める",
                        summary: "新しいHPは公開できる状態です。告知の準備に合わせて公開日を1つ選んでください。選んだ日に合わせて告知文と予約投稿を整えます。",
                        options: [.init(label: "11月15日（土）に公開", detail: "準備は完了。告知は前日に出します。", recommended: true),
                                  .init(label: "11月22日（土）に延期", detail: "写真を撮り直してから公開します。"),
                                  .init(label: "公開を保留する")],
                        impact: "公開日に合わせてSNSの告知予約が決まります。", deadline: iso(5),
                        source: .init(paseoAgentId: "a1", sessionId: nil, name: "HP｜公開準備"), createdAt: iso(-2)),
            LAADecision(id: "dec_0000000000000a02", title: "名刺の紙を選ぶ", summary: "試し刷りの2種から選んでください。",
                        options: [.init(label: "マットな白", detail: "文字がくっきり読めます。", recommended: true),
                                  .init(label: "生成りの紙", detail: "柔らかい印象です。")],
                        deadline: iso(72), source: .init(paseoAgentId: "a2", sessionId: nil, name: "Studio｜名刺"), createdAt: iso(-5)),
            undelivered,
            LAADecision(kind: .session, id: "ses_2222222222222222", title: "LAAアプリ｜通知の文面", summary: "どちらの文面にしますか？",
                        createdAt: iso(-30), sessionId: "ses_2222222222222222"),
        ]
    }

    private var undelivered: LAADecision {
        LAADecision(id: "dec_0000000000000a03", status: "answered", title: "週報の送り先を決める", summary: "週報をどこへ送るかを決めます。",
                    options: [.init(label: "Driveに保存", recommended: true), .init(label: "メールの下書き")],
                    source: .init(paseoAgentId: "a3", sessionId: nil, name: "週報｜作成"), createdAt: iso(-20),
                    answer: .init(optionIndex: 0, label: "Driveに保存", note: nil, answeredAt: iso(-1)),
                    delivery: .init(state: "failed", attempts: 1, deliveredAt: nil, error: "agent_archived"))
    }

    func testBoardLightAndDark() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let suffix = style == .dark ? "dark" : "light"
            let board = LAADecisionBoard()
            board.setForTesting(items)
            try capture(list(board), style: style, name: "decisions-list-\(suffix)")
            let empty = LAADecisionBoard()
            empty.setForTesting([])
            try capture(list(empty), style: style, name: "decisions-empty-\(suffix)")
            let old = LAADecisionBoard()
            old.setForTesting([], phase: .unsupported)
            try capture(list(old), style: style, name: "decisions-unsupported-\(suffix)")
            let offline = LAADecisionBoard()
            offline.setForTesting([], phase: .failed(LAABridgeError.networkUnreachable.japaneseText))
            try capture(list(offline), style: style, name: "decisions-offline-\(suffix)")
        }
    }

    func testDetailLightAndDark() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let suffix = style == .dark ? "dark" : "light"
            let board = LAADecisionBoard()
            board.setForTesting(items)
            try capture(detail(items[0], board: board, preselected: nil), style: style, name: "decisions-detail-\(suffix)")
            try capture(detail(items[0], board: board, preselected: .option(0)), style: style, name: "decisions-detail-chosen-\(suffix)")
            try capture(detail(undelivered, board: board, preselected: nil), style: style, name: "decisions-undelivered-\(suffix)")
            try capture(NavigationStack { LAADecisionCelebration(stored: false) {} .background(LAAColor.background.ignoresSafeArea()) },
                        style: style, name: "decisions-sent-\(suffix)", settle: 1.0)
        }
    }

    private func list(_ board: LAADecisionBoard) -> some View {
        NavigationStack {
            LAADecisionBoardView(board: board, drafts: LAAWorkDrafts.makeStore(fileURL: tempFile()), loadsOnAppear: false)
                .navigationTitle(Text(verbatim: "Work"))
                .navigationBarTitleDisplayMode(.large)
        }
    }

    private func detail(_ item: LAADecision, board: LAADecisionBoard, preselected: LAADecisionDetailView.Choice?) -> some View {
        NavigationStack {
            LAADecisionDetailView(item: item, board: board, drafts: LAAWorkDrafts.makeStore(fileURL: tempFile()), preselected: preselected)
        }
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("laa-decision-snapshot-\(UUID().uuidString).json")
    }

    private func capture<V: View>(_ view: V, style: UIUserInterfaceStyle, name: String, settle: TimeInterval = 0.5) throws {
        let bridge = LAABridgeSession(statusForTesting: .paired)
        let screen = view.environmentObject(bridge)
            .environment(\.locale, Locale(identifier: "ja_JP"))
            .preferredColorScheme(style == .dark ? .dark : .light)
        let host = UIHostingController(rootView: screen)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.verticalSizeClass = .regular
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        XCTAssertEqual(image.cgImage?.width, 440)
        XCTAssertEqual(image.cgImage?.height, 956)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
