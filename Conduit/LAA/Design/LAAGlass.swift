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
                    .foregroundStyle(LAAColor.filledButtonText)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent).tint(LAAColor.filledButton)
                .foregroundStyle(LAAColor.filledButtonText)
        } else {
            content.buttonStyle(.bordered)
        }
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

/// The tabs' shared heading: the brand above a Georgia title, under a bare
/// navigation bar whose controls are the only glass.
struct LAATabHeading: View {
    let title: String
    var identifier = ""

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: LAACopy.brand).laaTextStyle(.section).fontWeight(.bold).foregroundStyle(LAAColor.link)
            Text(verbatim: title).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier)
        }
    }
}
#endif
