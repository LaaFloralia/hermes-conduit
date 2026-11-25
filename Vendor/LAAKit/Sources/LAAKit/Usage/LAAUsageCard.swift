import SwiftUI

/// One limit window of a provider (e.g. 5 時間 / 週).
public struct LAAUsageWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    /// Remaining share 0–1; `nil` is unknown (○, empty bar).
    public let remaining: Double?
    public let value: String
    public let reset: String?

    public init(id: String, label: String, remaining: Double?, value: String, reset: String? = nil) {
        self.id = id; self.label = label; self.remaining = remaining; self.value = value; self.reset = reset
    }
}

/// A provider's usage: 1 pt rule outline, radius 16, padding 16; 18 pt icon + 16/500 name; windows in two
/// columns (gap 12 / 8) with a 12 pt label, 13/500 value, the 4 pt usage bar and a 12 pt reset time.
public struct LAAUsageCard: View {
    let name: String
    let icon: LAAIcon
    let windows: [LAAUsageWindow]
    @Environment(\.laaPalette) private var palette

    public init(name: String, icon: LAAIcon = .usage, windows: [LAAUsageWindow]) {
        self.name = name; self.icon = icon; self.windows = windows
    }

    public var body: some View {
        let t = LAAComponentToken.ProviderCard.self
        VStack(alignment: .leading, spacing: t.gap) {
            HStack(spacing: LAASpace.s8) {
                LAAIconImage(icon, size: t.headerIcon).foregroundStyle(palette.textMuted)
                Text(name).laaFont(t.headerName, weight: .medium).foregroundStyle(palette.text)
            }
            Grid(alignment: .topLeading, horizontalSpacing: t.windowColumnGap, verticalSpacing: t.windowRowGap) {
                ForEach(Array(stride(from: 0, to: windows.count, by: t.windowColumns)), id: \.self) { start in
                    GridRow {
                        ForEach(windows[start..<min(start + t.windowColumns, windows.count)]) { window in
                            LAAUsageWindowView(window: window)
                        }
                    }
                }
            }
        }
        .padding(t.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: t.radius, style: .continuous)
            .strokeBorder(palette.rule, lineWidth: t.outline))
        .accessibilityElement(children: .contain)
    }
}

struct LAAUsageWindowView: View {
    let window: LAAUsageWindow
    @Environment(\.laaPalette) private var palette

    var body: some View {
        let t = LAAComponentToken.ProviderCard.self
        VStack(alignment: .leading, spacing: LAASpace.s4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).laaFont(t.windowLabel).foregroundStyle(palette.textMuted)
                Spacer(minLength: LAASpace.s4)
                Text(window.value).laaFont(t.windowValue, weight: .medium).monospacedDigit()
                    .foregroundStyle(palette.text)
            }
            LAAUsageBar(remaining: window.remaining)
            if let reset = window.reset {
                Text(reset).laaFont(t.windowLabel).monospacedDigit().foregroundStyle(palette.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Provider cards: one column, at most 4 (later ones are dropped — show the rest elsewhere).
public struct LAAUsageCardList<Card: View>: View {
    let cards: [Card]
    public init(_ cards: [Card]) { self.cards = Array(cards.prefix(LAAComponentToken.ProviderCard.max)) }

    public var body: some View {
        VStack(spacing: LAAComponentToken.ProviderCard.gap) {
            ForEach(cards.indices, id: \.self) { cards[$0] }
        }
    }
}
