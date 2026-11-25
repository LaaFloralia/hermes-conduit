#if LAA_BUILD
import SwiftUI

/// Archiving in Work always asks first, and only OK archives. When the Mac
/// refuses (a session in the tree is still at work: 409 session_running),
/// nothing changes and the reason is said in full (2026-11-13: a refusal
/// shown as one cut-off line at the top of the list read as "archived").
struct LAAWorkArchivePrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// nil: a notice that only needs OK.
    let archive: (() -> Void)?

    static let confirmTitle = "アーカイブ"
    static let cancelTitle = "キャンセル"
    static let refusedTitle = "アーカイブできませんでした"
    static let running = "このセッション、またはその下の子のセッションが実行中か判断待ちのため、Macがアーカイブを断りました。セッションはそのまま残っています。終わってから、または停止してから、もう一度アーカイブしてください。"
    static let unreachable = "Macから結果が届かなかったため、アーカイブできたか確かめられません。一覧を読み直して確認してください。"

    static func session(_ session: LAAWorkSession, archive: @escaping () -> Void) -> Self {
        .init(title: "このセッションをアーカイブしますか？",
              message: "「\(session.name)」をアーカイブします。下にある子のセッションも一緒にアーカイブされます。アーカイブの一覧から戻せます。",
              archive: archive)
    }

    static func project(_ project: LAAWorkProject, archive: @escaping () -> Void) -> Self {
        .init(title: "このプロジェクトをアーカイブしますか？",
              message: "「\(project.name)」をアーカイブします。アーカイブの一覧から戻せます。",
              archive: archive)
    }

    static func refused(_ error: Error) -> Self {
        .init(title: refusedTitle, message: refusal(error), archive: nil)
    }

    /// Why an archive did not happen, in words the owner can act on.
    static func refusal(_ error: Error) -> String {
        if let error = error as? LAABridgeError { return error.japaneseText }
        guard let error = error as? LAABridgeHTTPError else { return unreachable }
        if error.code == "session_running" { return running }
        if error.status == 404 || error.status == 405 { return "MacのLAAアプリを最新にすると使えます。" }
        return LAAWorkHTTP.message(error)
    }
}

extension View {
    func laaWorkArchivePrompt(_ prompt: Binding<LAAWorkArchivePrompt?>) -> some View {
        modifier(LAAWorkArchiveAlert(request: prompt))
    }
}

private struct LAAWorkArchiveAlert: ViewModifier {
    @Binding var request: LAAWorkArchivePrompt?
    @State private var confirmedArchive: (() -> Void)?

    private var confirmation: Binding<LAAWorkArchivePrompt?> {
        Binding(get: { request?.archive != nil ? request : nil }, set: { item in
            if request?.archive != nil { request = item }
        })
    }

    func body(content: Content) -> some View {
        let refusal = request?.archive == nil ? request : nil
        return content
            // An alert supplies no dismissal completion. Wait for the sheet
            // to close before sending, so even a fast refusal can open its alert.
            .sheet(item: confirmation, onDismiss: performConfirmedArchive) { item in
                ScrollView {
                    VStack(alignment: .leading, spacing: LAASpacing.x4) {
                        Text(verbatim: item.title)
                            .laaTextStyle(.section)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("work.archive.title")
                        Text(verbatim: item.message).laaTextStyle(.body)
                        HStack {
                            Button(role: .cancel) { request = nil } label: { Text(verbatim: LAAWorkArchivePrompt.cancelTitle) }
                                .laaButton(.text)
                                .accessibilityIdentifier("work.archive.cancel")
                            Spacer()
                            Button {
                                confirmedArchive = item.archive
                                request = nil
                            } label: { Text(verbatim: LAAWorkArchivePrompt.confirmTitle) }
                            .laaButton(.primary)
                            .accessibilityIdentifier("work.archive.confirm")
                        }
                    }
                    .padding(LAASpacing.x6)
                }
                .presentationDetents([.medium, .large])
            }
            .alert(refusal?.title ?? "", isPresented: Binding(
                get: { request != nil && request?.archive == nil },
                set: { visible in if !visible, request?.id == refusal?.id { request = nil } }
            ), presenting: refusal) { _ in
                Button(role: .cancel) {} label: { Text(verbatim: "OK") }
            } message: { item in
                Text(verbatim: item.message)
            }
    }

    private func performConfirmedArchive() {
        let archive = confirmedArchive
        confirmedArchive = nil
        archive?()
    }
}
#endif
