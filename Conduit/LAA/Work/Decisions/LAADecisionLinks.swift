#if LAA_BUILD
import SwiftUI
import SafariServices

/// D-17: web addresses in a decision's summary, option detail and impact are
/// links. Only http(s) is detected; the text itself is never parsed as
/// Markdown, so an agent's words show exactly as written.
enum LAADecisionLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The http(s) addresses in `text`, in order, without duplicates.
    static func urls(in text: String) -> [URL] {
        var seen = Set<URL>()
        return matches(in: text).map(\.url).filter { seen.insert($0).inserted }
    }

    /// `text` with each address carrying `.link` and an underline; the
    /// surrounding view's tint colours it.
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for match in matches(in: text) {
            guard let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = match.url
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }

    /// VoiceOver's name for one link: 「リンクを開く example.com」.
    static func actionName(_ url: URL) -> String { "リンクを開く \(url.host() ?? url.absoluteString)" }

    private static func matches(in text: String) -> [(range: NSRange, url: URL)] {
        guard let detector, !text.isEmpty else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.host()?.isEmpty == false else { return nil }
            return (match.range, url)
        }
    }
}

/// A link waiting for the in-app browser.
struct LAADecisionBrowserPage: Identifiable { let id = UUID(); let url: URL }

/// Opens a decision's links: the in-app browser on the iPhone, the default
/// browser on the Mac.
struct LAADecisionLinkOpener: ViewModifier {
    @Binding var page: LAADecisionBrowserPage?

    /// The one rule for every way a link is opened (tap and VoiceOver action).
    static func open(_ url: URL, page: Binding<LAADecisionBrowserPage?>) -> OpenURLAction.Result {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return .discarded }
        #if targetEnvironment(macCatalyst)
        return .systemAction(url)
        #else
        page.wrappedValue = LAADecisionBrowserPage(url: url)
        return .handled
        #endif
    }

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in Self.open(url, page: $page) })
            .fullScreenCover(item: $page) { page in
                LAADecisionBrowser(url: page.url) { self.page = nil }.ignoresSafeArea()
            }
    }
}

private struct LAADecisionBrowser: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        controller.delegate = context.coordinator
        controller.preferredControlTintColor = UIColor(LAAColor.link)
        // UI tests assert the presentation, never the page.
        controller.view.accessibilityIdentifier = "work.decision.browser"
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onDone() }
    }
}

extension View {
    func laaDecisionLinks(_ page: Binding<LAADecisionBrowserPage?>) -> some View {
        modifier(LAADecisionLinkOpener(page: page))
    }
}
#endif
