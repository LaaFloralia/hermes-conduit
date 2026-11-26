#if !os(watchOS)
import ImageIO
import LAATokens
import QuartzCore
import SwiftUI

/// Shared render-server layers for both UIKit and AppKit. Only layout and state changes touch the app thread.
@MainActor final class LAAMarbleLayers {
    struct Config: Equatable {
        let style: LAAMarbleStyle
        let seed: UInt64
        let dark: Bool
        let moves: Bool
        let start: Date?
    }

    private typealias T = LAAAppSelection
    private static let driftKey = "laa.marble.drift"
    private static let frontKey = "laa.marble.front"
    private let root: CALayer
    private let spread = CALayer(), spreadMask = CAGradientLayer()
    private let veinBox = CALayer(), veinMask = CAGradientLayer()
    private let glow = CALayer(), glowBox = CALayer(), glowMask = CAGradientLayer()
    private let band = CAGradientLayer(), sheen = CAGradientLayer()
    private let cloud = LAAMarbleTileLayer(), main = LAAMarbleTileLayer(), hair = LAAMarbleTileLayer()
    private let glowMain = LAAMarbleTileLayer(), glowHair = LAAMarbleTileLayer()
    private var builtFor: PaintKey?
    private var runningFor: PlaybackKey?
    private var playedStart: Date?

    private struct PaintKey: Equatable {
        let bounds: CGRect
        let scale: CGFloat
        let style: LAAMarbleStyle
        let dark: Bool
        let seed: UInt64
    }

    private struct PlaybackKey: Equatable {
        let bounds: CGRect
        let style: LAAMarbleStyle
        let start: Date?
    }

    init(root: CALayer) {
        self.root = root
        let clear = Self.maskAlpha(0), opaque = Self.maskAlpha(1)
        for mask in [spreadMask, veinMask, glowMask, band] {
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
        }
        spreadMask.colors = [opaque, opaque, clear, clear]
        band.colors = [clear, Self.maskAlpha(T.bandShoulderShare), opaque, Self.maskAlpha(T.bandShoulderShare), clear]
        let half = T.bandShoulderAt / 2
        band.locations = [0, NSNumber(value: 0.5 - half), 0.5, NSNumber(value: 0.5 + half), 1]
        // CSS degrees: 90 is left to right.
        let radians = T.sheenAngleDeg * .pi / 180
        let dx = sin(radians) / 2, dy = -cos(radians) / 2
        sheen.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
        sheen.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
        sheen.locations = [0, 0.5, 1]
        root.addSublayer(spread)
        spread.addSublayer(veinBox)
        veinBox.mask = veinMask
        for tile in [cloud, main, hair] { veinBox.addSublayer(tile.layer) }
        spread.addSublayer(glow)
        glow.addSublayer(glowBox)
        glowBox.mask = glowMask
        for tile in [glowMain, glowHair] { glowBox.addSublayer(tile.layer) }
        glow.mask = band
        root.addSublayer(sheen)
        for box in [veinBox, glowBox] { box.shouldRasterize = true }
    }

    func update(_ config: Config, bounds: CGRect, scale: CGFloat, attached: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard bounds.width > 1, bounds.height > 1 else { stop(in: bounds); return }
        let paint = PaintKey(bounds: bounds, scale: scale, style: config.style, dark: config.dark, seed: config.seed)
        if paint != builtFor {
            layout(paint)
            builtFor = paint
        }
        guard attached, config.moves, !config.style.isPlain else {
            if runningFor != nil { stop(in: bounds) }
            return
        }
        let playback = PlaybackKey(bounds: bounds, style: config.style, start: config.start)
        guard runningFor != playback else { return }
        stop(in: bounds)
        runningFor = playback
        var delay = 0.0
        if let start = config.start, start != playedStart {
            playedStart = start
            let elapsed = max(0, Date().timeIntervalSince(start))
            if elapsed < T.selectionSeconds {
                playFront(in: bounds, elapsed: elapsed)
                delay = T.selectionSeconds - elapsed
            }
        }
        drift(in: bounds, style: config.style, after: delay)
    }

    private func layout(_ paint: PaintKey) {
        let bounds = paint.bounds
        let w = bounds.width, h = bounds.height
        for layer in [spread, veinBox, veinMask, glow, glowBox, glowMask] { layer.frame = bounds }
        for box in [veinBox, glowBox] { box.rasterizationScale = paint.scale }
        let style = paint.style, dark = paint.dark, tile = style.tileSize
        let shift = LAAMarble.offset(seed: paint.seed, tile: tile)
        let ink = style.model.ink.value(dark: dark), light = style.model.lightColor.value(dark: dark)
        let tiles: [(LAAMarbleTileLayer, String, T.RGB)] = [
            (cloud, T.assetCloud, ink), (main, T.assetMain, ink), (hair, T.assetHair, ink),
            (glowMain, T.assetMain, light), (glowHair, T.assetHair, light),
        ]
        for (target, asset, color) in tiles {
            target.paint(asset: asset, color: color, tile: tile, shift: shift, area: bounds.size, scale: paint.scale)
        }
        cloud.layer.opacity = Float(style.veinOpacity(T.cloudOpacity, dark: dark))
        main.layer.opacity = Float(style.veinOpacity(T.mainOpacity, dark: dark))
        hair.layer.opacity = Float(style.hairOpacity(dark: dark))
        let mainShare = max(0.0001, T.mainOpacity.value(dark: dark))
        glowHair.layer.opacity = Float(min(1, T.hairOpacity.value(dark: dark) / mainShare * style.step.tokens.hair))
        let label = LAAMarble.labelBand(width: w)
        for mask in [veinMask, glowMask] {
            mask.locations = label.locations.map { NSNumber(value: $0) }
            mask.colors = label.opacities.map(Self.maskAlpha)
        }
        let sheenOpacity = T.sheen.value(dark: dark) * min(1, style.intensity)
        let highlight = T.stone.lightColor.value(dark: false).cgColor
        sheen.colors = [highlight.copy(alpha: 0)!, highlight.copy(alpha: sheenOpacity)!, highlight.copy(alpha: 0)!]
        glow.opacity = Float(style.lightOpacity(dark: dark))
        band.bounds = CGRect(x: 0, y: 0, width: T.bandWidthRatio * w, height: h)
        sheen.bounds = CGRect(x: 0, y: 0, width: T.sheenWidthRatio * w, height: h)
        rest(in: bounds)
    }

    private func playFront(in bounds: CGRect, elapsed: Double) {
        let w = bounds.width, h = bounds.height
        let edge = T.frontWidthRatio / 2 / 4
        spreadMask.locations = [0, NSNumber(value: 0.5 - edge), NSNumber(value: 0.5 + edge), 1]
        spreadMask.bounds = CGRect(x: 0, y: 0, width: 4 * w, height: h)
        spreadMask.position = CGPoint(x: 1.5 * w, y: h / 2)
        spread.mask = spreadMask
        let (x1, y1, x2, y2) = LAAMotionToken.stateCurve
        for target in [spreadMask, band, sheen] as [CALayer] {
            let animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = T.frontFrom * w
            animation.toValue = T.frontTo * w
            animation.duration = T.selectionSeconds
            animation.timingFunction = CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
            animation.beginTime = target.convertTime(CACurrentMediaTime(), from: nil) - elapsed
            animation.preferredFrameRateRange = Self.frameRate
            target.add(animation, forKey: Self.frontKey)
        }
    }

    private func drift(in bounds: CGRect, style: LAAMarbleStyle, after delay: Double) {
        for target in [band, sheen] {
            let animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = T.travel.from * bounds.width
            animation.toValue = T.travel.to * bounds.width
            animation.duration = style.crossingSeconds
            animation.autoreverses = T.autoreverse
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.beginTime = target.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.preferredFrameRateRange = Self.frameRate
            target.add(animation, forKey: Self.driftKey)
        }
    }

    private func stop(in bounds: CGRect) {
        for layer in [band, sheen, spreadMask] as [CALayer] { layer.removeAllAnimations() }
        runningFor = nil
        spread.mask = nil
        rest(in: bounds)
    }

    private func rest(in bounds: CGRect) {
        band.position = CGPoint(x: T.restPosition * bounds.width, y: bounds.midY)
        sheen.position = band.position
    }

    private static var frameRate: CAFrameRateRange {
        CAFrameRateRange(minimum: 1, maximum: T.maxFrameRate, preferred: T.maxFrameRate)
    }

    // Masks use only the alpha channel; these are not visible palette colours.
    private nonisolated static func maskAlpha(_ alpha: Double) -> CGColor { CGColor(gray: 0, alpha: alpha) }
}

/// Two replicators tile one tinted image each; neither platform needs a per-frame draw delegate.
@MainActor private final class LAAMarbleTileLayer {
    let layer = CAReplicatorLayer()
    private let row = CAReplicatorLayer()
    private let stamp = CALayer()

    init() {
        layer.addSublayer(row)
        row.addSublayer(stamp)
    }

    func paint(asset: String, color: LAAAppSelection.RGB, tile: CGSize, shift: CGPoint, area: CGSize, scale: CGFloat) {
        guard tile.width >= 1, tile.height >= 1 else { return }
        layer.frame = CGRect(origin: CGPoint(x: -shift.x, y: -shift.y), size: area)
        row.frame = layer.bounds
        stamp.frame = CGRect(origin: .zero, size: tile)
        stamp.contents = LAAMarbleAssets.tile(asset, color: color, scale: scale)
        stamp.contentsScale = scale
        row.instanceCount = Int(ceil((area.width + shift.x) / tile.width))
        row.instanceTransform = CATransform3DMakeTranslation(tile.width, 0, 0)
        layer.instanceCount = Int(ceil((area.height + shift.y) / tile.height))
        layer.instanceTransform = CATransform3DMakeTranslation(0, tile.height, 0)
    }
}

@MainActor enum LAAMarbleAssets {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    static func source(_ asset: String, scale: Int) -> CGImage? {
        guard let url = Bundle.module.url(forResource: "\(asset)@\(scale)x", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func tile(_ asset: String, color: LAAAppSelection.RGB, scale: CGFloat) -> CGImage? {
        let resolution = Int(min(3, max(1, ceil(scale))))
        let key = "\(asset)|\(resolution)|\(color.r),\(color.g),\(color.b)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = source(asset, scale: resolution), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.draw(source, in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(color.cgColor)
        context.fill(rect)
        guard let image = context.makeImage() else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
#endif
