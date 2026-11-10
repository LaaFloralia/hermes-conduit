#if LAA_BUILD
import SwiftUI

/// Liquid Glass for LAA's own controls: search fields, filter chips and
/// action buttons. Reading surfaces (rows, cards, note bodies) stay opaque.
/// Before iOS 26 and with Reduce Transparency the control falls back to the
/// opaque card with a hairline.
private struct LAAGlassControl<S: Shape>: ViewModifier {
    let shape: S
    let selected: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular.tint(selected ? LAAColor.selectionFill : nil).interactive(), in: shape)
        } else {
            content.background(selected ? LAAColor.selectionFill : LAAColor.surface, in: shape)
                .overlay(shape.stroke(LAAColor.separator, lineWidth: 1))
        }
    }
}

private struct LAAGlassButton: ViewModifier {
    let prominent: Bool

    // A prominent button sets its own label colour: a screen's text colour
    // would otherwise reach the label and sit dark on the fill.
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).tint(LAAColor.filledButton)
                    .modifier(LAAProminentLabel())
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent).tint(LAAColor.filledButton)
                .modifier(LAAProminentLabel())
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// A prominent button's label. A Mac window that isn't frontmost greys the
/// fill, and the white label would vanish on it, so it falls back to the
/// system's secondary text there.
private struct LAAProminentLabel: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(LAAProminentActiveLabel())
        } else {
            content.foregroundStyle(LAAColor.filledButtonText)
        }
    }
}

@available(iOS 18.0, *)
private struct LAAProminentActiveLabel: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content.foregroundStyle(appearsActive ? AnyShapeStyle(LAAColor.filledButtonText) : AnyShapeStyle(.secondary))
    }
}

extension View {
    func laaGlass<S: Shape>(in shape: S, selected: Bool = false) -> some View {
        modifier(LAAGlassControl(shape: shape, selected: selected))
    }

    /// The system's glass button style; `prominent` is the one primary
    /// action on a screen. Large, so the capsule keeps the 44pt target.
    func laaGlassButton(prominent: Bool = false) -> some View {
        modifier(LAAGlassButton(prominent: prominent)).controlSize(.large)
    }
}

/// Compatibility entry point; all tabs use the same unbranded heading.
struct LAATabHeading: View {
    let title: String
    var identifier = ""
    var body: some View { LAAScreenHeader(title: title, identifier: identifier) }
}
#endif
