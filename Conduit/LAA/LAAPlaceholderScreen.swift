#if LAA_BUILD

import SwiftUI

struct LAAPlaceholderScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let tab: LAATab
    let onRequestSettings: () -> Void

    /// Which segment of the screen's switch is picked. It moves, since the
    /// switch is part of the final screen, but every segment shows the same
    /// state until the Bridge has data.
    @State private var segment = 0
    private var state: LAAScreenState { .current }

    private var segments: [String] { LAACopy.segments(tab) }

    var body: some View {
        ZStack {
            LAAColors.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x6) {
                    heading
                    if !segments.isEmpty {
                        segmentSwitch
                    }
                    if tab == .usage {
                        usageRows
                    }
                    stateBody
                }
                .padding(.horizontal, LAASpacing.x4)
                .padding(.top, LAASpacing.x2)
                .padding(.bottom, LAASpacing.x8)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(tab.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onRequestSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text(verbatim: LAACopy.settings))
            }
        }
        .tint(LAAColors.teal)
    }

    // MARK: - Heading and switch

    /// Screen heading.
    private var heading: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: tab.title)
                .font(LAAFont.largeHeading)
                .foregroundStyle(LAAColors.ink)
                .accessibilityAddTraits(.isHeader)
            if tab == .usage {
                Text(verbatim: LAACopy.refreshedAt + " " + LAACopy.never)
                    .font(LAAFont.caption)
                    .foregroundStyle(LAAColors.muted)
            }
        }
    }

    @ViewBuilder
    private var segmentSwitch: some View {
        if dynamicTypeSize.isAccessibilitySize {
            segmentPicker.pickerStyle(.menu)
        } else {
            segmentPicker.pickerStyle(.segmented)
        }
    }

    private var segmentPicker: some View {
        Picker(selection: $segment, label: Text(verbatim: tab.title)) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, title in
                Text(verbatim: title).tag(index)
            }
        }
        .accessibilityLabel(Text(verbatim: tab.title))
    }

    // MARK: - Usage: unknown is distinct from zero

    private var usageRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(LAACopy.usageRows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: LAASpacing.x3) {
                    Text(verbatim: row)
                        .font(LAAFont.row)
                        .foregroundStyle(LAAColors.ink)
                    Spacer(minLength: LAASpacing.x2)
                    Image(systemName: "circle")
                        .font(.caption)
                        .foregroundStyle(LAAColors.muted)
                    Text(verbatim: LAACopy.notFetched)
                        .font(LAAFont.row)
                        .foregroundStyle(LAAColors.muted)
                        .monospacedDigit()
                }
                .padding(.vertical, LAASpacing.x3)
                if index < LAACopy.usageRows.count - 1 {
                    Rectangle()
                        .fill(LAAColors.hairline)
                        .frame(height: 1)
                }
            }
        }
        .padding(.horizontal, LAASpacing.x4)
        .background(LAAColors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LAAColors.hairline, lineWidth: 1)
        )
    }

    // MARK: - State

    @ViewBuilder
    private var stateBody: some View {
        switch state {
        case .bridgeNotPaired:
            card {
                stateLine(symbol: "circle", word: LAACopy.notConnected, colour: LAAColors.muted)
                Text(verbatim: LAACopy.bridgeNotPairedTitle)
                    .font(.headline)
                    .foregroundStyle(LAAColors.ink)
                Text(verbatim: LAACopy.bridgeNotPairedBody)
                    .font(LAAFont.row)
                    .foregroundStyle(LAAColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .loading:
            card {
                HStack(spacing: LAASpacing.x3) {
                    ProgressView()
                        .tint(LAAColors.teal)
                    Text(verbatim: LAACopy.loading)
                        .font(LAAFont.row)
                        .foregroundStyle(LAAColors.muted)
                }
            }
        case .empty:
            card {
                stateLine(symbol: "circle.fill", word: LAACopy.noItems, colour: LAAColors.teal)
                Text(verbatim: LAACopy.emptyReason(tab))
                    .font(LAAFont.row)
                    .foregroundStyle(LAAColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed:
            card {
                stateLine(symbol: "exclamationmark.triangle.fill", word: LAACopy.needsAttention, colour: LAAColors.plum)
                Text(verbatim: LAACopy.failureTitle)
                    .font(.headline)
                    .foregroundStyle(LAAColors.ink)
                Text(verbatim: LAACopy.failureBody)
                    .font(LAAFont.row)
                    .foregroundStyle(LAAColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stateLine(symbol: String, word: String, colour: Color) -> some View {
        HStack(spacing: LAASpacing.x2) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(colour)
            Text(verbatim: word)
                .font(LAAFont.caption.weight(.medium))
                .foregroundStyle(colour)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            content()
        }
        .padding(LAASpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LAAColors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LAAColors.hairline, lineWidth: 1)
        )
    }
}

#endif
