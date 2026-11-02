#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

@MainActor
final class LAAConversationHeaderSnapshotTests: XCTestCase {
    func testNarrowNamesAndDynamicTypeLightAndDark() throws {
        for width: CGFloat in [375, 440] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                for dark in [false, true] {
                    try capture(width: width, size: size, dark: dark)
                }
            }
        }
    }

    private func capture(width: CGFloat, size: DynamicTypeSize, dark: Bool) throws {
        let available = try XCTUnwrap(LAAConversationHeaderLayout.nameWidth(screenWidth: width))
        XCTAssertLessThanOrEqual(available + 2 * LAAConversationHeaderLayout.sideReserve, width)
        XCTAssertGreaterThanOrEqual(LAAConversationHeaderLayout.controlHeight, 44)
        let screen = NavigationStack {
            LAAColor.background.ignoresSafeArea()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {} label: {
                            Image(systemName: "chevron.left").frame(width: 44, height: 44)
                        }.accessibilityLabel(Text(verbatim: LAACopy.back))
                    }
                    ToolbarItem(placement: .principal) {
                        LAAEmployeeHeader(profile: "laa-ciel-uncensored", name: "Ciel（無検閲）",
                                          status: "この会話はテキスト専用です", isObscured: true,
                                          compact: available < 140 || size.isAccessibilitySize)
                            .frame(maxWidth: available)
                            .frame(minHeight: 44)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        LAAConversationControls {
                            LAAEmployeeCallButton(reason: nil) {}
                            Button {} label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        }
                    }
                }
        }
        .environment(\.dynamicTypeSize, size)
        .preferredColorScheme(dark ? .dark : .light)
        let host = UIHostingController(rootView: screen)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 956)
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.userInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "header-\(Int(width))-\(size.isAccessibilitySize ? "accessibility" : "normal")-\(dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
