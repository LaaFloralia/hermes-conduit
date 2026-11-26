import SwiftUI

/// Liquid Glass for the operating layer only (bars, the composer and its controls, floating actions, transient
/// panels). Native `glassEffect` on iOS/macOS/watchOS 26+; otherwise, and with Reduce Transparency, an opaque
/// `surface` with a 1 pt `rule` edge (Increase Contrast: `text` edge). Never on prose, lists, tables or numbers.
public struct LAAGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tinted: Bool
    @LAAReduceTransparency private var reduceTransparency
    @Environment(\.laaPalette) private var palette

    public func body(content: Content) -> some View {
        if !reduceTransparency, #available(iOS 26, macOS 26, watchOS 26, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(shape.fill(palette.surface))
                .overlay(shape.strokeBorder(palette.rule, lineWidth: LAAStroke.rule))
        }
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    private var glass: Glass {
        var g = Glass.regular
        if tinted { g = g.tint(palette.accent.opacity(0.18)) }
        if interactive { g = g.interactive() }
        return g
    }
}

public extension View {
    /// Glass in a shape. `tinted` is for the one primary control on a screen.
    func laaGlass<S: InsettableShape>(in shape: S, interactive: Bool = true, tinted: Bool = false) -> some View {
        modifier(LAAGlassModifier(shape: shape, interactive: interactive, tinted: tinted))
    }

    /// Glass capsule (OS-standard glass controls may be capsules; opaque controls may not).
    func laaGlassCapsule(interactive: Bool = true, tinted: Bool = false) -> some View {
        // laa-design:allow pill OS-standard glass controls keep the OS capsule shape.
        laaGlass(in: Capsule(), interactive: interactive, tinted: tinted)
    }
}

/// One glass group: siblings inside merge and morph together and count as a single group on the screen
/// (the composer, the working strip and the jump button are one cluster). Do not nest clusters.
public struct LAAGlassCluster<Content: View>: View {
    let spacing: Double
    let content: Content

    public init(spacing: Double = LAAGlassToken.clusterSpacing, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(iOS 26, macOS 26, watchOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
