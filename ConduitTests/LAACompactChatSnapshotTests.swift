#if LAA_BUILD && DEBUG
import SwiftUI
import XCTest
@testable import Conduit

/// Hosts the production conversation at the owner's single-screen size even
/// when the available simulator itself is the wider, shorter iPhone Duo.
@MainActor
final class LAACompactChatSnapshotTests: XCTestCase {
    private let suiteName = "LAACompactChatSnapshotTests"
    private let canvas = CGRect(x: 0, y: 0, width: 440, height: 956)

    func testCompactChatLightAndDark() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            try capture(style: style)
        }
    }

    private func capture(style: UIUserInterfaceStyle) throws {
        let languageStore = AppLanguageStore.shared
        let previousLanguage = languageStore.selection
        let previousLanguageValue = UserDefaults.standard.string(forKey: AppLanguageStore.defaultsKey)
        languageStore.select(.localization("ja"))
        defer {
            languageStore.select(previousLanguage)
            if let previousLanguageValue {
                UserDefaults.standard.set(previousLanguageValue, forKey: AppLanguageStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppLanguageStore.defaultsKey)
            }
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let fixture = LAABackgroundFixture(chatFixtureOverride: "rich", defaultsSuiteName: suiteName)
        fixture.state.themePreference = style == .dark ? .dark : .light
        XCTAssertEqual(fixture.state.composerPlaceholder, "Cielにメッセージを送信…")
        let bridge = LAABridgeSession(statusForTesting: .unpaired)
        let calls = LAAEmployeeCallCoordinator(control: SnapshotCallControl())
        var swiftUISizeClass: UserInterfaceSizeClass?
        let screen = NavigationStack {
            V2ConversationScreen()
        }
        .environmentObject(fixture.state)
        .environmentObject(bridge)
        .environmentObject(calls)
        .environment(\.locale, Locale(identifier: "ja"))
        .overlay {
            SizeClassProbe { swiftUISizeClass = $0 }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        let host = UIHostingController(rootView: screen)
        let previousWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: canvas)
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.verticalSizeClass = .regular
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }

        // Allow the real SwiftUI transcript, toolbar and bundled avatar to
        // settle before rasterizing the window.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if swiftUISizeClass == .compact,
               firstView(in: host.view, matching: ImagePasteTextView.self) != nil,
               textHosts(in: host.view).contains(where: { $0.displayedText.contains("優先すること") }) {
                break
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(window.bounds, canvas)
        XCTAssertEqual(host.view.bounds.size, canvas.size)
        XCTAssertEqual(window.traitCollection.horizontalSizeClass, .compact)
        XCTAssertEqual(host.traitCollection.horizontalSizeClass, .compact)
        XCTAssertEqual(swiftUISizeClass, .compact)
        XCTAssertEqual(host.traitCollection.userInterfaceStyle, style)
        XCTAssertFalse(ChatSidePanel.fits(width: canvas.width))
        XCTAssertFalse(V2SplitLayout.isSplit(width: canvas.width))
        XCTAssertTrue(textHosts(in: host.view).contains { $0.displayedText.contains("優先すること") },
                      "The real rich-message content must be mounted")
        let editor = try XCTUnwrap(firstView(in: host.view, matching: ImagePasteTextView.self))
        let editorFrame = editor.convert(editor.bounds, to: window)
        XCTAssertGreaterThan(editorFrame.minY, canvas.height / 2)
        XCTAssertLessThanOrEqual(editorFrame.maxY, canvas.maxY)
        XCTAssertGreaterThan(editorFrame.width, 0)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: canvas, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: canvas, afterScreenUpdates: true))
        }
        XCTAssertEqual(image.size, canvas.size)
        XCTAssertEqual(image.cgImage?.width, 1320)
        XCTAssertEqual(image.cgImage?.height, 2868)
        let attachment = XCTAttachment(image: image)
        attachment.name = "compact-440x956-\(style == .dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func firstView<T: UIView>(in root: UIView, matching type: T.Type) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = firstView(in: child, matching: type) { return match }
        }
        return nil
    }

    private func textHosts(in root: UIView) -> [SelectableTextViewHostView] {
        let own = (root as? SelectableTextViewHostView).map { [$0] } ?? []
        return own + root.subviews.flatMap { textHosts(in: $0) }
    }
}

private struct SizeClassProbe: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let report: (UserInterfaceSizeClass?) -> Void

    var body: some View {
        Color.clear
            .onAppear { report(sizeClass) }
            .onChange(of: sizeClass) { _, value in report(value) }
    }
}

@MainActor
private final class SnapshotCallControl: LAAEmployeeCallControlling {
    var unavailableReason: String? { nil }
    var onUpdate: ((LAAEmployeeCallSnapshot) -> Void)?
    func start(_ context: LAAEmployeeCallContext) {}
    func setMuted(_ muted: Bool) {}
    func setSpeaker(_ speaker: Bool) {}
    func end() {}
}
#endif
