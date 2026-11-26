#if LAA_BUILD
import LAAKit
import SwiftUI

/// The document column is interior paper, not another card or a control.
/// Only its line measure is capped; the paper stretches to the window.
extension View {
    func laaDocPaper() -> some View {
        modifier(LAADocPaper())
    }
}

/// A split column's hard scroll edge is a system white band on Catalyst.
/// The reading column already clears the toolbar; avoid that extra layer.
struct LAADocPaperTopEdge: ViewModifier {
    @Environment(\.laaDesktop) private var desktop

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), desktop {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

private struct LAADocPaper: ViewModifier {
    @Environment(\.laaDesktop) private var desktop
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        let canvas = desktop ? LAACanvas.mac : .iphone
        content
            .frame(maxWidth: desktop ? canvas.readingMeasure : .infinity, alignment: .leading)
            .padding(.horizontal, typeSize.isAccessibilitySize ? canvas.marginCompact : canvas.margin)
            .padding(.vertical, LAASpacing.x6)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct LAADocTitle: View {
    let title: String
    @Environment(\.laaDesktop) private var desktop
    @ScaledMetric(relativeTo: .largeTitle) private var phoneSize = LAACanvas.iphone.title
    @ScaledMetric(relativeTo: .largeTitle) private var desktopSize = LAACanvas.mac.title

    var body: some View {
        Text(verbatim: title)
            .font(LAAKit.LAAType.display(size: desktop ? desktopSize : phoneSize))
            .foregroundStyle(LAAColor.text)
            .accessibilityAddTraits(.isHeader)
    }
}
#endif
