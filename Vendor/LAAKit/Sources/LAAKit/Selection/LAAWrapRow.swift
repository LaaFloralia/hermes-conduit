#if !os(watchOS)
import LAATokens
import SwiftUI

/// Children at their ideal widths, left to right, moving whole to the next
/// line when the row is full: the model and effort capsules (and Chat's Fast)
/// wrap instead of cutting a name. A child wider than the row alone gets the
/// row's width. Each line is centred on its tallest child.
struct LAAWrapRow: Layout {
    var spacing: CGFloat = LAASpace.s8
    var lineSpacing: CGFloat = LAASpace.s8

    /// The line each width falls on, for an `available` width (nil: one line).
    static func lines(_ widths: [CGFloat], available: CGFloat?, spacing: CGFloat) -> [Int] {
        var line = 0, x: CGFloat = 0, out: [Int] = []
        for (index, width) in widths.enumerated() {
            if index > 0, let available, x + spacing + width > available + 0.5 { line += 1; x = 0 }
            else if index > 0 { x += spacing }
            out.append(line)
            x += width
        }
        return out
    }

    private func frames(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let sizes = subviews.map { subview -> CGSize in
            let ideal = subview.sizeThatFits(.unspecified)
            guard let available, ideal.width > available + 0.5 else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: available, height: nil))
        }
        let line = Self.lines(sizes.map(\.width), available: available, spacing: spacing)
        var frames: [CGRect] = [], y: CGFloat = 0, width: CGFloat = 0
        for current in Set(line).sorted() {
            let members = line.indices.filter { line[$0] == current }
            let height = members.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for index in members {
                if x > 0 { x += spacing }
                frames.append(CGRect(x: x, y: y + (height - sizes[index].height) / 2,
                                     width: sizes[index].width, height: sizes[index].height))
                x += sizes[index].width
            }
            width = max(width, x)
            y += height + lineSpacing
        }
        return (frames, CGSize(width: width, height: max(0, y - lineSpacing)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = frames(ProposedViewSize(width: bounds.width, height: bounds.height), subviews).frames
        for (subview, frame) in zip(subviews, placed) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
#endif
