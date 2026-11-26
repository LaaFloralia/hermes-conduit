#if LAA_BUILD && LAA_WIDGET_TEST && os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// The employee call card drawn from the widget extension's own views
/// (LAAStaffCallLiveActivity.swift), laid out at the system's sizes on an
/// iPhone 16 Pro Max: the Lock Screen banner (the card is 440 − 2×14 wide),
/// the expanded island and the compact and minimal pairs. The black island
/// shapes are drawn here; inside them every view is the widget's. The PNGs
/// are kept in the result bundle for the design check.
@MainActor
final class LAAAmbientSnapshotTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func attributes(_ profile: String = "laa-cfo", _ name: String = "Morgan") -> LAAStaffCallAttributes {
        LAAStaffCallAttributes(profile: profile, name: name, link: nil)
    }

    func testCallLockScreenStates() throws {
        for phase in [LAAStaffCallPhase.connecting, .speaking, .listening, .muted] {
            let state = LAAStaffCallAttributes.ContentState(phase: phase, connectedAt: phase == .connecting ? nil : start)
            try capture("call-lock-\(phase.rawValue)", size: CGSize(width: 412, height: 84)) {
                LAAStaffCallLockScreen(attributes: attributes(), state: state)
                    .frame(width: 412, height: 84)
                    .background(LAAStaffActivityStyle.glass)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
            }
        }
    }

    func testCallDynamicIsland() throws {
        let state = LAAStaffCallAttributes.ContentState(phase: .speaking, connectedAt: start)
        try capture("call-island-expanded", size: CGSize(width: 412, height: 120)) {
            HStack(alignment: .center, spacing: 8) {
                LAAStaffCallIsland.expandedLeading(attributes())
                LAAStaffCallIsland.expandedCenter(attributes(), state)
                LAAStaffCallIsland.expandedTrailing(state)
            }
            .padding(.horizontal, 18)
            .frame(width: 412, height: 120)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 44))
            .environment(\.colorScheme, .dark)
        }
        try capture("call-island-compact", size: CGSize(width: 260, height: 37)) {
            HStack(spacing: 0) {
                LAAStaffCallIsland.compactLeading(attributes(), state).padding(.leading, 8)
                Spacer(minLength: 125)
                LAAStaffCallIsland.compactTrailing(state).padding(.trailing, 10)
            }
            .frame(width: 260, height: 37)
            .background(Color.black)
            .clipShape(Capsule())
            .environment(\.colorScheme, .dark)
        }
        try capture("call-island-minimal-monet", size: CGSize(width: 37, height: 37)) {
            LAAStaffCallIsland.minimal(attributes("laa-monet", "Monet"), state)
                .frame(width: 37, height: 37)
                .background(Color.black)
                .clipShape(Circle())
        }
    }

    func testUnknownProfileKeepsTheSymbol() throws {
        let state = LAAStaffCallAttributes.ContentState(phase: .listening, connectedAt: start)
        try capture("call-lock-unknown-profile", size: CGSize(width: 412, height: 84)) {
            LAAStaffCallLockScreen(attributes: attributes("default", "Agent"), state: state)
                .frame(width: 412, height: 84)
                .background(LAAStaffActivityStyle.glass)
                .clipShape(RoundedRectangle(cornerRadius: 24))
        }
    }

    private func capture<V: View>(_ name: String, size: CGSize, @ViewBuilder _ view: () -> V) throws {
        let host = UIHostingController(rootView: view().environment(\.colorScheme, .dark))
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.backgroundColor = .clear
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.backgroundColor = .clear
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
