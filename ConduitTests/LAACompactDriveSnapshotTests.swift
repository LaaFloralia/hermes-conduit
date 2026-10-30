#if LAA_BUILD && DEBUG
import SwiftUI
import XCTest
@testable import Conduit

@MainActor
final class LAACompactDriveSnapshotTests: XCTestCase {
    func testScreensAtOwnerSizeLightAndDark() throws {
        LAADriveData.snapshotFixture = "normal"
        defer { LAADriveData.snapshotFixture = nil }
        let bridge = LAABridgeSession(statusForTesting: .unpaired)
        let video = try item("video1", "Sample video", "video/quicktime")
        let image = try item("image1", "Portrait", "image/png")
        let pdf = try item("doc1", "Notes", "application/pdf")
        for style in [UIUserInterfaceStyle.light, .dark] {
            try capture("assets", style, bridge) { AnyView(LAAAssetsView(onRequestSettings: {})) }
            try capture("details", style, bridge) { AnyView(LAADriveDetailView(item: video)) }
            try capture("player", style, bridge) { AnyView(LAADrivePreviewView(item: video)) }
            try capture("image", style, bridge) { AnyView(LAADrivePreviewView(item: image)) }
            try capture("pdf", style, bridge) { AnyView(LAADrivePreviewView(item: pdf)) }
        }
    }

    private func item(_ id: String, _ name: String, _ mime: String) throws -> LAADriveItem {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "name": name, "mimeType": mime,
                                                                "kind": "file", "downloadable": true])
        return try JSONDecoder().decode(LAADriveItem.self, from: data)
    }

    private func capture(_ name: String, _ style: UIUserInterfaceStyle, _ bridge: LAABridgeSession,
                         content: () -> AnyView) throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let insets = previous?.safeAreaInsets ?? .zero
        let host = UIHostingController(rootView: NavigationStack { content() }
            .environmentObject(bridge).preferredColorScheme(style == .dark ? .dark : .light))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440 + insets.left + insets.right, height: 956)
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.verticalSizeClass = .regular
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        host.view.layoutIfNeeded()
        XCTAssertEqual(window.bounds.width - host.view.safeAreaInsets.left - host.view.safeAreaInsets.right, 440, accuracy: 0.5)
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = true
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let crop = CGRect(x: host.view.safeAreaInsets.left * 3, y: 0, width: 1320, height: 2868)
        let cgImage = try XCTUnwrap(rendered.cgImage?.cropping(to: crop))
        let image = UIImage(cgImage: cgImage, scale: 3, orientation: .up)
        XCTAssertEqual(image.size, CGSize(width: 440, height: 956))
        let attachment = XCTAttachment(image: image)
        attachment.name = "drive-\(name)-\(style == .dark ? "dark" : "light")-440x956"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
