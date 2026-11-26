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
    static let scale = LAAType.catalystScale

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

    /// Geometry uses Mac system points, not Catalyst UIKit points.
    static func comfortableFrame(in visible: CGRect) -> CGRect {
        let horizontalMargin: CGFloat = 32
        let verticalMargin: CGFloat = 32
        let aspect: CGFloat = 1.6
        let roomWidth = max(1, visible.width - horizontalMargin)
        let roomHeight = max(1, visible.height - verticalMargin)
        let width = min(1440, roomWidth, max(minimumWidth * scale, floor(roomHeight * aspect)))
        let height = min(900, roomHeight, max(minimumHeight * scale, floor(width / aspect)))
        return CGRect(x: floor(visible.midX - width / 2), y: floor(visible.midY - height / 2),
                      width: width, height: height)
    }

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
    @ObservedObject private var commands = LAAMacCommandsModel.shared
    func makeUIView(context: Context) -> ConstraintView { ConstraintView() }
    func updateUIView(_ view: ConstraintView, context: Context) { view.fit(ifRequested: commands.fitWindow) }

    final class ConstraintView: UIView {
        private var lastRequest = LAAMacCommandsModel.shared.fitWindow
        private var fitted: CGRect?
        private var previous: CGRect?

        func fit(ifRequested request: Int) {
            guard request != lastRequest, let scene = window?.windowScene else { return }
            lastRequest = request
            let current = scene.effectiveGeometry.systemFrame
            guard !current.isEmpty, let visible = Self.visibleFrame(containing: current) else { return }
            let target = LAAMacWindow.comfortableFrame(in: visible)
            if let fitted, let previous, current.insetBy(dx: -2, dy: -2).contains(fitted), visible.contains(previous) {
                scene.requestGeometryUpdate(.Mac(systemFrame: previous))
                self.previous = nil
                self.fitted = nil
            } else {
                previous = current
                fitted = target
                scene.requestGeometryUpdate(.Mac(systemFrame: target))
            }
        }

        private static func visibleFrame(containing window: CGRect) -> CGRect? {
            // Catalyst does not import NSScreen, but AppKit's documented screen metrics are
            // available in the process. Resize the scene itself through public UIKit geometry.
            func rect(_ screen: NSObject, _ property: String) -> CGRect? {
                let selector = NSSelectorFromString(property)
                guard let getter = screen.method(for: selector) else { return nil }
                typealias GetRect = @convention(c) (AnyObject, Selector) -> CGRect
                // A typed getter avoids unboxing an AppKit NSRect with UIKit's NSValue API.
                return unsafeBitCast(getter, to: GetRect.self)(screen, selector)
            }
            guard let type = NSClassFromString("NSScreen") as? NSObject.Type,
                  let screens = type.perform(NSSelectorFromString("screens"))?.takeUnretainedValue() as? [NSObject],
                  let primary = screens.first.flatMap({ rect($0, "frame") }) else { return nil }
            func systemRect(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX, y: primary.maxY - rect.maxY, width: rect.width, height: rect.height)
            }
            func overlap(_ screen: NSObject) -> CGFloat {
                guard let frame = rect(screen, "frame") else { return 0 }
                let area = systemRect(frame).intersection(window)
                return area.isNull ? 0 : area.width * area.height
            }
            guard let screen = screens.max(by: { overlap($0) < overlap($1) }),
                  let frame = rect(screen, "visibleFrame") else { return nil }
            return systemRect(frame)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }
        func apply() {
            guard let scene = window?.windowScene else { return }
            // The scene settles its own restrictions just after it connects,
            // which undoes the first attempt; apply again once it has.
            scene.titlebar?.titleVisibility = .hidden
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
            let tallCapture = LAALabCaptureFixture.enabled && size.height >= 1050
            if tallCapture { autoHideDockForCapture() }
            let y = tallCapture ? min(80, max(0, scene.screen.bounds.height - size.height)) : 80
            scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: CGPoint(x: 80, y: y), size: size)))
            #endif
        }

        #if DEBUG
        /// Presentation options apply only while this dev process is in
        /// front; do not change the real Dock setting or the installed app.
        private func autoHideDockForCapture() {
            guard let type = NSClassFromString("NSApplication") as? NSObject.Type,
                  let app = type.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject else { return }
            let selector = NSSelectorFromString("setPresentationOptions:")
            guard let method = app.method(for: selector) else { return }
            typealias SetPresentation = @convention(c) (AnyObject, Selector, UInt) -> Void
            // AppKit NSApplication.PresentationOptions.autoHideDock.
            unsafeBitCast(method, to: SetPresentation.self)(app, selector, 1)
        }

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
