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
        let deviceInsets = previousWindow?.safeAreaInsets ?? .zero
        let window = UIWindow(windowScene: scene)
        // On Duo, put the physical rail outside the 440-point viewport.
        // UIKit then lays out the real screen and navigation bar in the same
        // usable width as a single-screen phone, without modifying either.
        window.frame = CGRect(x: 0, y: 0, width: canvas.width + deviceInsets.left + deviceInsets.right,
                              height: canvas.height)
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
        XCTAssertEqual(window.bounds.height, canvas.height, accuracy: 0.5)
        XCTAssertEqual(host.view.bounds.size, window.bounds.size)
        XCTAssertEqual(window.bounds.width - host.view.safeAreaInsets.left - host.view.safeAreaInsets.right,
                       canvas.width, accuracy: 0.5, "The actual conversation viewport must be 440 points")
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
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let viewport = CGRect(x: host.view.safeAreaInsets.left * format.scale, y: 0,
                              width: canvas.width * format.scale, height: canvas.height * format.scale)
        let cropped = try XCTUnwrap(rendered.cgImage?.cropping(to: viewport))
        let image = UIImage(cgImage: cropped, scale: format.scale, orientation: .up)
        XCTAssertEqual(image.size, canvas.size)
        XCTAssertEqual(image.cgImage?.width, 1320)
        XCTAssertEqual(image.cgImage?.height, 2868)
        XCTAssertTrue(hasVisibleContent(image), "The rendered snapshot must not be blank")
        let bubbleTrailing = try XCTUnwrap(bubbleTrailingEdge(image, style: style), "Own bubble must be visible")
        XCTAssertEqual(canvas.width - bubbleTrailing, LAASpacing.horizontal, accuracy: 2,
                       "The own bubble must end at the chat's trailing margin")
        let headerTrailing = try XCTUnwrap(trailingControlEdge(image, rows: 10..<60), "The header controls must be visible")
        XCTAssertEqual(canvas.width - headerTrailing, LAASpacing.horizontal, accuracy: 3,
                       "The header controls must end at the chat's trailing margin")
        let composerTrailing = try XCTUnwrap(trailingControlEdge(image, rows: 800..<940), "The composer controls must be visible")
        XCTAssertEqual(canvas.width - composerTrailing, LAASpacing.horizontal, accuracy: 3,
                       "The send control must end at the chat's trailing margin")
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

    /// Measures the actual rendered bubble, so a 440-point window containing
    /// a narrower conversation fails even if its outer bounds look correct.
    private func bubbleTrailingEdge(_ image: UIImage, style: UIUserInterfaceStyle) -> CGFloat? {
        guard let cgImage = image.cgImage else { return nil }
        let width = Int(canvas.width), height = Int(canvas.height), components = 4
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(LAAColor.ownBubble).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        let expected = [red, green, blue].map { Int(($0 * 255).rounded()) }
        var pixels = [UInt8](repeating: 0, count: width * height * components)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * components,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            var trailing: Int?
            for y in 0..<height {
                var start: Int?
                for x in 0...width {
                    let offset = (y * width + min(x, width - 1)) * components
                    let matches = x < width && (0..<3).allSatisfy { abs(Int(buffer[offset + $0]) - expected[$0]) <= 3 }
                    if matches && start == nil { start = x }
                    if !matches, let runStart = start {
                        if x - runStart >= 80 { trailing = max(trailing ?? 0, x) }
                        start = nil
                    }
                }
            }
            return trailing.map(CGFloat.init)
        }
    }

    /// The glass edge differs from the plain paper at the far right of the
    /// same row. Crop first so other controls cannot satisfy the assertion.
    private func trailingControlEdge(_ image: UIImage, rows: Range<Int>) -> CGFloat? {
        guard let cgImage = image.cgImage else { return nil }
        let width = Int(canvas.width), height = rows.count, components = 4
        let crop = CGRect(x: 0, y: CGFloat(rows.lowerBound) * image.scale,
                          width: CGFloat(cgImage.width), height: CGFloat(height) * image.scale)
        guard let section = cgImage.cropping(to: crop) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * components)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * components,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(section, in: CGRect(x: 0, y: 0, width: width, height: height))
            var trailing: Int?
            for y in 0..<height {
                let background = (y * width + width - 5) * components
                for x in (width / 2)..<(width - 8) {
                    let offset = (y * width + x) * components
                    if (0..<3).contains(where: { abs(Int(buffer[offset + $0]) - Int(buffer[background + $0])) >= 8 }) {
                        trailing = max(trailing ?? 0, x + 1)
                    }
                }
            }
            return trailing.map(CGFloat.init)
        }
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
