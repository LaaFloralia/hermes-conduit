#if !os(watchOS)
import LAATokens
import QuartzCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct LAAPickerLayerHost {
    enum Content {
        case marble(LAAMarbleLayers.Config)
        case glow(color: LAAAppSelection.RGB, opacity: Double)
    }

    let content: Content
    @Environment(\.displayScale) private var displayScale
}

#if canImport(UIKit)
extension LAAPickerLayerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> LAAPickerNativeView { LAAPickerNativeView() }

    func updateUIView(_ view: LAAPickerNativeView, context: Context) {
        view.setContent(content, scale: displayScale)
    }
}

final class LAAPickerNativeView: UIView {
    private let contentLayer = LAAPickerContentLayer()

    init() {
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        layer.addSublayer(contentLayer.layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setContent(_ content: LAAPickerLayerHost.Content, scale: CGFloat) {
        contentLayer.update(content, bounds: bounds, scale: scale, attached: window != nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateLayers()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateLayers()
    }

    private func updateLayers() { contentLayer.update(bounds: bounds, attached: window != nil) }
}
#elseif canImport(AppKit)
extension LAAPickerLayerHost: NSViewRepresentable {
    func makeNSView(context: Context) -> LAAPickerNativeView { LAAPickerNativeView() }

    func updateNSView(_ view: LAAPickerNativeView, context: Context) {
        view.setContent(content, scale: displayScale)
    }
}

final class LAAPickerNativeView: NSView {
    private let contentLayer = LAAPickerContentLayer()
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // The hosted layer uses the same top-left layout as the UIKit view.
        contentLayer.layer.isGeometryFlipped = true
        layer?.addSublayer(contentLayer.layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setContent(_ content: LAAPickerLayerHost.Content, scale: CGFloat) {
        contentLayer.update(content, bounds: bounds, scale: scale, attached: window != nil)
    }

    override func layout() {
        super.layout()
        updateLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayers()
    }

    private func updateLayers() { contentLayer.update(bounds: bounds, attached: window != nil) }
}
#endif

@MainActor private final class LAAPickerContentLayer {
    let layer = CALayer()
    private var content: LAAPickerLayerHost.Content?
    private var scale: CGFloat = 1
    private var marble: LAAMarbleLayers?

    func update(_ content: LAAPickerLayerHost.Content, bounds: CGRect, scale: CGFloat, attached: Bool) {
        self.content = content
        self.scale = scale
        update(bounds: bounds, attached: attached)
    }

    func update(bounds: CGRect, attached: Bool) {
        guard let content else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.frame = bounds
        switch content {
        case .marble(let config):
            if marble == nil { marble = LAAMarbleLayers(root: layer) }
            marble?.update(config, bounds: layer.bounds, scale: scale, attached: attached)
        case .glow(let color, let opacity):
            typealias T = LAAAppSelection
            layer.shadowColor = color.cgColor
            layer.shadowOpacity = Float(opacity)
            layer.shadowRadius = T.glowRadiusPt
            layer.shadowOffset = CGSize(width: 0, height: T.glowOffsetPt)
            layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: T.cornerRadiusPt,
                                      cornerHeight: T.cornerRadiusPt, transform: nil)
        }
    }
}
#endif
