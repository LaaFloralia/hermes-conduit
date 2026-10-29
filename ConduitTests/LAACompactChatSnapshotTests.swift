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
        let light = try capture(style: .light)
        let dark = try capture(style: .dark)
        XCTAssertGreaterThan(averageBrightness(light), averageBrightness(dark) + 0.15,
                             "Light and dark snapshots must render their respective appearance")
    }

    private func capture(style: UIUserInterfaceStyle) throws -> UIImage {
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
        let fixture = LAABackgroundFixture(chatFixtureOverride: "rich", defaultsSuiteName: suiteName,
                                           conversationID: "compact-snapshot-\(UUID().uuidString)")
        fixture.state.adoptProfileHermesNames([(profile: "laa-ciel", displayName: "Ciel")])
        fixture.state.themePreference = style == .dark ? .dark : .light
        let backgroundKey = try XCTUnwrap(LAAConversationScope.current(fixture.state))
        XCTAssertEqual(LAABackgroundStore.shared.setting(for: backgroundKey).kind, .paper)
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
        .preferredColorScheme(style == .dark ? .dark : .light)
        .overlay {
            SizeClassProbe { swiftUISizeClass = $0 }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        let host = UIHostingController(rootView: screen)
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let previousWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previousWindow?.windowScene ?? scenes.first,
                                 "The hosted conversation needs a window scene to render")
        let window = UIWindow(windowScene: scene)
        window.frame = canvas
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
        XCTAssertTrue(LAACompactHeaderLayout.isInline(width: canvas.width, sizeClass: .compact))
        XCTAssertFalse(LAACompactHeaderLayout.isInline(width: 466, sizeClass: .compact))
        XCTAssertFalse(LAACompactHeaderLayout.isInline(width: canvas.width, sizeClass: .regular))
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
        XCTAssertTrue(hasVisibleContent(image), "The rendered snapshot must not be blank")
        let attachment = XCTAttachment(image: image)
        attachment.name = "compact-440x956-\(style == .dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
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

    private func hasVisibleContent(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = 64, height = 128, bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * bytesPerPixel,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            var darkest = UInt8.max, brightest = UInt8.min
            for offset in stride(from: 0, to: buffer.count, by: bytesPerPixel) {
                let value = max(buffer[offset], buffer[offset + 1], buffer[offset + 2])
                darkest = min(darkest, value)
                brightest = max(brightest, value)
            }
            return brightest > 40 && Int(brightest) - Int(darkest) > 20
        }
    }

    private func averageBrightness(_ image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 0 }
        let width = 32, height = 64, bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * bytesPerPixel,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return 0 }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            let total = stride(from: 0, to: buffer.count, by: bytesPerPixel).reduce(0) { sum, offset in
                sum + Int(buffer[offset]) + Int(buffer[offset + 1]) + Int(buffer[offset + 2])
            }
            return Double(total) / Double(width * height * 3 * 255)
        }
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
