#if LAA_BUILD
import SwiftUI

struct LAADriveOperatingRulesView: View {
    enum Surface: String {
        case drive, studio
        var source: String { self == .drive ? "Drive" : LAACopy.tabTitle(.studio) }
    }
    private struct Rules: Decodable { let markdown: String }

    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let surface: Surface
    @State private var markdown: String?
    @State private var failed = false
    @State private var missing = false
    @State private var attempt = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                Text(verbatim: surface.source + " / Rules").laaTextStyle(.secondary)
                    .foregroundStyle(LAAColor.secondaryText)
                if let markdown {
                    MarkdownText(source: markdown, foregroundStyle: LAAColor.text)
                        .environment(\.laaRichContentStyle, true)
                        .accessibilityIdentifier("laa.doc.rules.body")
                } else if failed {
                    Text(verbatim: missing ? "Driveの所定の場所に運用ルールがありません。" : "Driveの接続を確認して、もう一度お試しください。")
                        .laaTextStyle(.body).foregroundStyle(LAAColor.attention)
                    Button("Retry") { attempt += 1 }
                } else {
                    LAALoadingDots()
                }
            }
            .laaDocPaper()
        }
        .background(LAAColor.surface.ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task(id: [bridge.revision, attempt]) {
            markdown = nil; failed = false; missing = false
            do {
                let source: String
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-laa-doc-rules-fixture") {
                    source = "# 運用ルール\n\n資料は所定のフォルダに保存します。\n\n## 置き場所\n\n| 場所 | 用途 |\n| --- | --- |\n| 制作 | 原稿と納品物 |\n\n## 名前\n\n- 版はファイル名ではなく履歴で管理\n\n`YYYY-MM-DD`"
                } else {
                    source = try await fetch()
                }
                #else
                source = try await fetch()
                #endif
                try Task.checkCancellation()
                markdown = source
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                missing = (error as? LAABridgeHTTPError)?.code == "rules_missing"
                failed = true
            }
        }
    }

    private func fetch() async throws -> String {
        let response: LAABridgeResponse<Rules> = try await bridge.request(method: "GET", path: "/v1/drive/rules/\(surface.rawValue)")
        return response.data.markdown
    }
}
#endif
