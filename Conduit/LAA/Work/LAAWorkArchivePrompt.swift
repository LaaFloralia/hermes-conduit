#if LAA_BUILD
import SwiftUI
import UIKit

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
    @State private var shown: LAAWorkArchivePrompt?
    @State private var anchor = UIView()

    func body(content: Content) -> some View {
        let presented = shown
        return content
            .background(WindowAnchor(view: anchor).frame(width: 0, height: 0).accessibilityHidden(true))
            .alert(presented?.title ?? "", isPresented: Binding(
                get: { shown != nil },
                set: { visible in
                    guard !visible, shown?.id == presented?.id else { return }
                    shown = nil
                    if request?.id == presented?.id { request = nil }
                }
            ), presenting: presented) { item in
                if let archive = item.archive {
                    Button(role: .cancel) {} label: { Text(verbatim: LAAWorkArchivePrompt.cancelTitle) }
                    Button { archive() } label: { Text(verbatim: LAAWorkArchivePrompt.confirmTitle) }
                        .accessibilityIdentifier("work.archive.confirm")
                } else {
                    Button(role: .cancel) {} label: { Text(verbatim: "OK") }
                }
            } message: { item in
                Text(verbatim: item.message)
            }
            .task(id: request?.id) { await presentRequestedAlert() }
    }

    private func presentRequestedAlert() async {
        guard let next = request, shown?.id != next.id else { return }
        // A fast refusal can arrive while the confirmation is closing. Keep
        // it queued until the old alert and its UIKit transition are gone.
        while shown != nil || nativeAlertIsClosingOrVisible {
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { return }
        }
        guard !Task.isCancelled, request?.id == next.id else { return }
        shown = next
    }

    private var nativeAlertIsClosingOrVisible: Bool {
        var presenter = anchor.window?.rootViewController
        while let current = presenter {
            if current is UIAlertController || current.transitionCoordinator?.viewController(forKey: .from) is UIAlertController {
                return true
            }
            presenter = current.presentedViewController
        }
        return false
    }

    private struct WindowAnchor: UIViewRepresentable {
        let view: UIView
        func makeUIView(context: Context) -> UIView { view }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }
}
#endif
