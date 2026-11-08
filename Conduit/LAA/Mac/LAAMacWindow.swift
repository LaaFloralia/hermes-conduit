#if LAA_BUILD && targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Window geometry is independent of text and control styling tokens.
///
/// Catalyst keeps the "Scale Interface to Match iPad" idiom, so one UIKit
/// point is drawn at about 0.77 Mac points. The numbers below are the Mac
/// sizes the desktop layout is designed for, divided by that scale: a
/// 1280×820 Mac window is 1662×1065 UIKit points. The window resizes freely
/// above the minimum (full screen and Split View included), so a wide
/// MacBook or Mac mini display gets a wide layout instead of a stretched
/// phone.
enum LAAMacWindow {
    /// UIKit points per Mac point under "Scale Interface to Match iPad".
    static let scale: CGFloat = 0.77

    /// 1280×820 Mac points: the default desktop window.
    static let initialWidth: CGFloat = 1662
    static let initialHeight: CGFloat = 1065
    /// 900×600 Mac points: narrow enough for Split View, wide enough for a
    /// list beside its detail.
    static let minimumWidth: CGFloat = 1169
    static let minimumHeight: CGFloat = 779
    /// Large enough for any display; the screen, not this, is the limit.
    static let maximumWidth: CGFloat = 8000
    static let maximumHeight: CGFloat = 5000

    #if DEBUG
    /// `-laa-mac-window 1280x820` asks the window for that size in Mac
    /// points, so `scripts/laa/mac-screens.sh` captures the sizes the
    /// desktop layout is designed for without driving the window from
    /// outside. A release build has no such argument.
    static var requestedFrame: CGSize? {
        guard let parts = argument(after: "-laa-mac-window")?.lowercased().split(separator: "x"),
              parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width >= 600, height >= 400 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// `-laa-mac-snapshot <file.png>` has the window draw itself into that
    /// file once it has settled at its size, for `mac-screens.sh
    /// --self-render` where the session may not record the screen.
    static var snapshotPath: String? { argument(after: "-laa-mac-snapshot") }

    /// `-laa-mac-snapshot-delay <seconds>`: how long it waits first (6 by
    /// default), for a fixture whose chat opens later.
    static var snapshotDelay: Double { argument(after: "-laa-mac-snapshot-delay").flatMap(Double.init) ?? 6 }

    private static func argument(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    #endif
}

struct LAAMacWindowConstraints: UIViewRepresentable {
    func makeUIView(context: Context) -> ConstraintView { ConstraintView() }
    func updateUIView(_ view: ConstraintView, context: Context) { view.apply() }

    final class ConstraintView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }
        func apply() {
            guard let scene = window?.windowScene else { return }
            // The scene settles its own restrictions just after it connects,
            // which undoes the first attempt; apply again once it has.
            setRestrictions(scene)
            requestFrame(scene)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak scene] in
                guard let self, let scene else { return }
                self.setRestrictions(scene)
                self.requestFrame(scene)
            }
        }

        private func setRestrictions(_ scene: UIWindowScene) {
            scene.sizeRestrictions?.minimumSize = CGSize(
                width: LAAMacWindow.minimumWidth, height: LAAMacWindow.minimumHeight
            )
            // Without a maximum the window stops at the size it opened with,
            // which is what kept the Mac at a phone-shaped frame: full screen
            // and Split View need room to grow.
            scene.sizeRestrictions?.maximumSize = CGSize(
                width: LAAMacWindow.maximumWidth, height: LAAMacWindow.maximumHeight
            )
        }

        private func requestFrame(_ scene: UIWindowScene) {
            #if DEBUG
            scheduleSnapshot()
            guard let size = LAAMacWindow.requestedFrame else { return }
            scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: CGPoint(x: 80, y: 80), size: size)))
            #endif
        }

        #if DEBUG
        private var snapshotScheduled = false

        /// Once, after the geometry request and the first content have
        /// landed: drawn at the Mac's Retina pixels (two per Mac point).
        private func scheduleSnapshot() {
            guard !snapshotScheduled, let path = LAAMacWindow.snapshotPath else { return }
            snapshotScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + LAAMacWindow.snapshotDelay) { [weak self] in
                guard let window = self?.window else { return }
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2 * LAAMacWindow.scale
                format.opaque = true
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        #endif
    }
}
#endif
