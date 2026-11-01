#if LAA_BUILD && DEBUG
import SwiftUI
import XCTest
@testable import Conduit

@MainActor
final class LAACompactStudioSnapshotTests: XCTestCase {
    func testScreensAtOwnerSizeLightAndDark() throws {
        defer { LAAStudioData.snapshotFixture = nil; LAAStudioData.fixtureRecords = [:] }
        let bridge = LAABridgeSession(statusForTesting: .unpaired)
        let normal = try LAAStudioData.sample("normal")
        let project = try XCTUnwrap(normal.projects.first)
        let record = try XCTUnwrap(normal.requests.first)
        for style in [UIUserInterfaceStyle.light, .dark] {
            LAAStudioData.snapshotFixture = "normal"
            try capture("works", style, bridge) { AnyView(LAAAssetsView(onRequestSettings: {}, initialStudioSelected: true)) }
            try capture("requests", style, bridge) { AnyView(LAAAssetsView(onRequestSettings: {}, initialStudioSelected: true, initialStudioSection: 1)) }
            try capture("work", style, bridge) { AnyView(LAAStudioWorkView(project: project)) }
            try capture("create", style, bridge) { AnyView(LAAStudioCreateView(snapshot: normal)) }
            try capture("request-approval", style, bridge) { AnyView(LAAStudioRequestView(initial: record, initialProject: project)) }
            try capture("image", style, bridge) { AnyView(LAAStudioImageView(name: "Cover", path: nil)) }
            let path = "/v1/studio/media/\(project.id)/\(String(repeating: "a", count: 64)).mp4"
            let asset = LAAStudioAsset(id: "video1", name: "Film", kind: "video", url: nil, poster: nil, unavailable: nil, previewOnly: nil)
            try capture("player", style, bridge) { AnyView(LAAStudioPlayerView(asset: asset, path: path)) }
            for mode in ["empty", "disconnected", "offline", "error", "unpaired"] {
                LAAStudioData.snapshotFixture = mode
                try capture("works-\(mode)", style, bridge) { AnyView(LAAAssetsView(onRequestSettings: {}, initialStudioSelected: true)) }
            }
            for mode in ["unsupported", "long"] {
                LAAStudioData.snapshotFixture = mode
                let fixture = try LAAStudioData.sample(mode)
                let sample = try XCTUnwrap(fixture.requests.first)
                try capture("request-\(mode)", style, bridge) { AnyView(LAAStudioRequestView(initial: sample, initialProject: fixture.projects.first)) }
            }
        }
    }

    func testV2ScreensAtOwnerSizeLightAndDark() throws {
        defer { LAAStudioData.snapshotFixture = nil }
        LAAStudioData.snapshotFixture = "v2"
        let bridge = LAABridgeSession(statusForTesting: .unpaired)
        let snapshot = try LAAStudioData.sample("v2")
        let project = try XCTUnwrap(snapshot.projects.first)
        for style in [UIUserInterfaceStyle.light, .dark] {
            try capture("v2-works", style, bridge) { AnyView(LAAAssetsView(onRequestSettings: {}, initialStudioSelected: true)) }
            try capture("v2-library", style, bridge) { AnyView(LAAAssetsView(onRequestSettings: {}, initialStudioSelected: true, initialStudioSection: 2)) }
            try capture("v2-work", style, bridge) { AnyView(LAAStudioWorkView(project: project, snapshot: snapshot)) }
            try capture("v2-review", style, bridge) {
                AnyView(LAAStudioReviewView(snapshot: snapshot, project: project, target: .project,
                                            targetName: project.title, revision: project.revision, reviews: []))
            }
        }
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
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let crop = CGRect(x: host.view.safeAreaInsets.left, y: 0, width: 440, height: 956)
        let cgImage = try XCTUnwrap(rendered.cgImage?.cropping(to: crop))
        XCTAssertEqual(cgImage.width, 440); XCTAssertEqual(cgImage.height, 956)
        let attachment = XCTAttachment(image: UIImage(cgImage: cgImage))
        attachment.name = "studio-\(name)-\(style == .dark ? "dark" : "light")-440x956"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
