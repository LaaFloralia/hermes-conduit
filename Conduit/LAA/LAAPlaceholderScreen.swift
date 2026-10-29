#if LAA_BUILD

import SwiftUI

struct LAAPlaceholderScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var bridge: LAABridgeSession
    @State private var showPairing = false
    @State private var connectionError: LAABridgeError?
    let tab: LAATab
    let onRequestSettings: () -> Void

    /// Which segment of the screen's switch is picked. It moves, since the
    /// switch is part of the final screen, but every segment shows the same
    /// state until the Bridge has data.
    @State private var segment = 0
    private var state: LAAScreenState {
        if bridge.status == .paired && connectionError != nil { return .failed }
        return .current(bridge.status)
    }

    private var segments: [String] { LAACopy.segments(tab) }

    @ViewBuilder var body: some View {
        if tab == .source {
            LAAAssetsView(onRequestSettings: onRequestSettings)
        } else {
            placeholderBody
        }
    }

    private var placeholderBody: some View {
        ZStack {
            LAAColors.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x6) {
                    heading
                    if !segments.isEmpty {
                        segmentSwitch
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
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .task(id: bridge.revision) { await verifyConnection() }
    }

    private func verifyConnection() async {
        guard bridge.status == .paired else { connectionError = nil; return }
        do {
            try await bridge.verify()
            connectionError = nil
        } catch let error as LAABridgeError {
            connectionError = error
        } catch is CancellationError {
            return
        } catch { connectionError = .networkUnreachable }
    }

    // MARK: - Heading and switch

    /// Screen heading.
    private var heading: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: tab.title)
                .font(LAAFont.largeHeading)
                .foregroundStyle(LAAColors.ink)
                .accessibilityAddTraits(.isHeader)
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

    // MARK: - State

    @ViewBuilder
    private var stateBody: some View {
        switch state {
        case .bridgeNotPaired:
            card {
                stateLine(symbol: "circle", word: LAACopy.notConnected, colour: LAAColors.muted)
                Text(verbatim: LAACopy.bridgeNotPairedBody)
                    .font(LAAFont.row)
                    .foregroundStyle(LAAColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showPairing = true } label: { Text(verbatim: "Macに接続する") }
                    .buttonStyle(.borderedProminent)
            }
        case .revoked:
            card {
                stateLine(symbol: "circle", word: LAACopy.notConnected, colour: LAAColors.muted)
                Text(verbatim: "この端末の接続が無効になりました。新しいコードで接続してください。")
                    .foregroundStyle(LAAColors.ink)
                Button { showPairing = true } label: { Text(verbatim: "Macに接続する") }
                    .buttonStyle(.borderedProminent)
            }
        case .connected:
            card {
                Text(verbatim: "この画面は準備中です。")
                    .foregroundStyle(LAAColors.muted)
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
                Text(verbatim: connectionError?.japaneseText ?? LAACopy.failureBody)
                    .font(LAAFont.row)
                    .foregroundStyle(LAAColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if connectionError != nil {
                    Button { Task { await verifyConnection() } } label: { Text(verbatim: "もう一度確認") }
                }
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
