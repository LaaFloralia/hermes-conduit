#if LAA_BUILD && targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Settings on the Mac: its own window beside the main one, as a Mac app's
/// settings are, instead of a sheet over the sections. The main window
/// builds the page, since it owns the Bridge session the pages read, and
/// hands it here; this window only shows it. Asking again brings the same
/// window forward rather than opening a second one.
@MainActor
final class LAAMacSettingsWindow: ObservableObject {
    static let shared = LAAMacSettingsWindow()
    static let sceneID = "laa-settings"
    /// 860×640 Mac points: the settings column with a margin either side.
    static let initialWidth: CGFloat = 1117
    static let initialHeight: CGFloat = 831
    /// 720×520 Mac points.
    static let minimumWidth: CGFloat = 935
    static let minimumHeight: CGFloat = 675

    @Published fileprivate private(set) var content: AnyView?
    @Published fileprivate private(set) var closeRequest = 0
    fileprivate weak var scene: UIWindowScene?
    private var onClose: (() -> Void)?

    var isOpen: Bool { content != nil }

    /// Shows `content`, opening the window or bringing it forward.
    func show(_ content: AnyView, onClose: @escaping () -> Void, open: (String) -> Void) {
        self.content = content
        self.onClose = onClose
        if let session = scene?.session {
            UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil)
        } else {
            open(Self.sceneID)
        }
    }

    /// Closes the window, if it is open.
    func close() {
        guard isOpen else { return }
        closeRequest += 1
    }

    fileprivate func attach(_ scene: UIWindowScene) {
        self.scene = scene
        scene.title = LAACopy.settings
        scene.sizeRestrictions?.minimumSize = CGSize(width: Self.minimumWidth, height: Self.minimumHeight)
    }

    fileprivate func didClose() {
        scene = nil
        content = nil
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }
}

/// The Settings window's root. A window macOS brings back at launch, before
/// anyone asked for Settings, has nothing to show and closes itself.
struct LAAMacSettingsScene: View {
    @ObservedObject private var window = LAAMacSettingsWindow.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let content = window.content {
                content.environment(\.laaSettingsInWindow, true)
            } else {
                LAAColor.background
            }
        }
        .frame(minWidth: LAAMacSettingsWindow.minimumWidth, minHeight: LAAMacSettingsWindow.minimumHeight)
        .background(LAAColor.background.ignoresSafeArea())
        .background(SceneReader { window.attach($0) })
        .onAppear { if window.content == nil { dismissWindow() } }
        .onDisappear { window.didClose() }
        .onChange(of: window.closeRequest) { _, _ in dismissWindow() }
    }

    private struct SceneReader: UIViewRepresentable {
        let found: (UIWindowScene) -> Void
        func makeUIView(context: Context) -> ReaderView { ReaderView(found: found) }
        func updateUIView(_ view: ReaderView, context: Context) {}

        final class ReaderView: UIView {
            let found: (UIWindowScene) -> Void
            init(found: @escaping (UIWindowScene) -> Void) {
                self.found = found
                super.init(frame: .zero)
            }
            required init?(coder: NSCoder) { nil }
            override func didMoveToWindow() {
                super.didMoveToWindow()
                if let scene = window?.windowScene { found(scene) }
            }
        }
    }
}
#endif

#if LAA_BUILD
import SwiftUI

private struct LAASettingsInWindowKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Settings is in a window of its own (the Mac), which closes from its
    /// title bar: the page drops its Done button.
    var laaSettingsInWindow: Bool {
        get { self[LAASettingsInWindowKey.self] }
        set { self[LAASettingsInWindowKey.self] = newValue }
    }
}
#endif
