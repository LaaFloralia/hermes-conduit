#if !os(watchOS)
import LAATokens
import SwiftUI

struct LAAPickerGlass: ViewModifier {
    let style: LAAMarbleStyle
    let seed: UInt64
    let active: Bool
    let start: Date?

    @Environment(\.laaPalette) private var palette
    @Environment(\.displayScale) private var displayScale
    @LAAReduceTransparency private var reduceTransparency
    @LAAReduceMotion private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private typealias T = LAAAppSelection
    private var shape: RoundedRectangle { .init(cornerRadius: T.cornerRadiusPt, style: .continuous) }

    func body(content: Content) -> some View {
        let decorated = content.background {
            if !style.isPlain {
                marble.clipShape(shape)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        decoratedGlass(decorated)
    }

    @ViewBuilder private func decoratedGlass(_ content: some View) -> some View {
        if #available(iOS 26, macOS 26, *), !reduceTransparency {
            content
                .glassEffect(.regular.tint(Color.clear).interactive(), in: shape)
                .background {
                    if !style.isPlain {
                        LAAPickerLayerHost(content: .glow(color: style.model.glow, opacity: style.glowOpacity(dark: palette.isDark)))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        } else {
            content
                .background(palette.surface, in: shape)
                .overlay {
                    shape.strokeBorder(palette.rule, lineWidth: LAAStroke.rule / max(1, displayScale))
                        .allowsHitTesting(false)
                }
        }
    }

    private var marble: some View {
        let dark = palette.isDark
        let highlight = T.stone.lightColor.value(dark: false).color
        let shadow = Color(laa: LAAThemeSets.set(id: palette.themeID).colors(dark: true).bg)
        let moves = active && onScreen && scenePhase != .background && !reduceMotion && !reduceTransparency && !lowPower
        return ZStack {
            // laa-design:allow gradient Adopted appSelection marble body (2026-11-15).
            shape.fill(LinearGradient(colors: [style.model.bodyTop.value(dark: dark).color,
                                               style.model.bodyBottom.value(dark: dark).color],
                                       startPoint: .top, endPoint: .bottom))
                .opacity(style.bodyOpacity(dark: dark))
            LAAPickerLayerHost(content: .marble(.init(style: style, seed: seed, dark: dark, moves: moves,
                                                     start: moves ? start : nil)))
            GeometryReader { geometry in
                let inset = T.topGlossInsetPt, height = geometry.size.height
                EllipticalGradient(colors: [highlight.opacity(T.topGloss.value(dark: dark)), highlight.opacity(0)],
                                   center: .top, startRadiusFraction: 0, endRadiusFraction: 1)
                    .frame(width: max(0, geometry.size.width - 2 * inset), height: 2 * T.topGlossHeightRatio * height)
                    .frame(width: geometry.size.width, height: T.topGlossHeightRatio * height, alignment: .top)
                    .clipped()
                    .offset(y: inset)
                // laa-design:allow gradient Adopted appSelection inner depth (2026-11-15).
                LinearGradient(stops: [
                    .init(color: shadow.opacity(0), location: max(0, 1 - T.bottomDepthRadiusPt / max(1, height))),
                    .init(color: shadow.opacity(T.bottomDepth.value(dark: dark)), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            // The inner top highlight fades before it can read as an outline.
            // laa-design:allow gradient Adopted appSelection inner top highlight (2026-11-15).
            shape.strokeBorder(LinearGradient(stops: [
                .init(color: highlight.opacity(T.rimLight.value(dark: dark)), location: 0),
                .init(color: highlight.opacity(0), location: 0.12),
            ], startPoint: .top, endPoint: .bottom), lineWidth: LAAStroke.rule)
        }
        .onAppear {
            onScreen = true
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onDisappear { onScreen = false }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}
#endif
