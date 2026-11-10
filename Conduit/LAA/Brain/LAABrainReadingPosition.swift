#if LAA_BUILD
import SwiftUI

/// Session-only positions, owned by the Doc tab and scoped to its selected vault.
@MainActor final class LAABrainReadingPositions: ObservableObject {
    private var offsets: [String: CGFloat] = [:]
    func offset(for key: String) -> CGFloat { offsets[key] ?? 0 }
    func remember(_ offset: CGFloat, for key: String) {
        guard offset.isFinite, offset >= 0 else { return }
        if offsets.count >= 100, offsets[key] == nil { offsets.removeAll(keepingCapacity: true) }
        offsets[key] = offset
    }
}

struct LAABrainReadingPosition: ViewModifier {
    let store: LAABrainReadingPositions
    let key: String
    let loaded: Bool
    let hasAnchor: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(LAABrainTrackedReadingPosition(store: store, key: key, loaded: loaded, hasAnchor: hasAnchor))
        } else { content }
    }
}

private struct BrainReadingGeometry: Equatable { let offset: CGFloat; let maximum: CGFloat }

@available(iOS 18.0, *)
private struct LAABrainTrackedReadingPosition: ViewModifier {
    let store: LAABrainReadingPositions
    let key: String
    let loaded: Bool
    let hasAnchor: Bool
    @State private var position = ScrollPosition()
    @State private var phase: ScrollPhase = .idle
    @State private var restoredKey: String?
    @State private var maximumOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content.scrollPosition($position)
            .onScrollPhaseChange { _, next in phase = next }
            .onScrollGeometryChange(for: BrainReadingGeometry.self) { geometry in
                BrainReadingGeometry(offset: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                                     maximum: max(0, geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom))
            } action: { _, geometry in
                maximumOffset = geometry.maximum
                if loaded, restoredKey != key, !hasAnchor, geometry.maximum >= store.offset(for: key) {
                    position.scrollTo(y: store.offset(for: key)); restoredKey = key
                } else if loaded, restoredKey == key, phase.isScrolling { store.remember(geometry.offset, for: key) }
            }
            .task(id: loaded ? key : nil) {
                guard loaded, restoredKey != key else { return }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                if !hasAnchor { position.scrollTo(y: min(maximumOffset, store.offset(for: key))) }
                restoredKey = key
            }
    }
}
#endif
