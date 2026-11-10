#if LAA_BUILD
import SwiftUI

struct LAAWorkDecisionSummary: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var board: LAADecisionBoard
    @ObservedObject var drafts: ComposerDraftStore
    @Binding var showAll: Bool
    @State private var selected: LAADecision?

    var body: some View {
        if !board.items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Decisions").font(.system(size: 13, weight: .semibold)).foregroundStyle(LAAColor.secondaryText)
                VStack(spacing: 0) {
                    ForEach(Array(board.items.prefix(3))) { item in
                        Button { selected = item } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "questionmark").foregroundStyle(LAAColor.attention).frame(width: 20)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: item.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                                    if let source = item.sourceLine { Text(verbatim: source).font(.system(size: 13)).foregroundStyle(LAAColor.secondaryText).lineLimit(1) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(12).frame(minHeight: 64).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("work.decision.\(item.id)")
                        if item.id != board.items.prefix(3).last?.id { Divider().padding(.leading, 44) }
                    }
                }.background(LAAColor.surface, in: RoundedRectangle(cornerRadius: 16))
                if board.items.count > 3 {
                    Button("すべて表示") { showAll = true }.frame(minHeight: 44).accessibilityIdentifier("work.decisions.all")
                }
            }.accessibilityIdentifier("work.decisions.summary")
            .sheet(item: $selected) { item in
                NavigationStack {
                    LAADecisionDetailView(item: item, board: board, drafts: drafts, onAnswered: { board.remove($0.id) }) { _ in selected = nil; Task { await board.load(bridge) } }
                }.environmentObject(bridge).environment(\.laaDesktop, false).laaSheetSize(.page)
            }
        } else if case .failed = board.phase {
            LAAWorkFailure(text: "判断を取得できません") { Task { await board.load(bridge) } }
        }
    }
}

struct LAAWorkSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3) { _ in
                HStack(spacing: 12) {
                    Circle().fill(LAAColor.subtleSurface).frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(LAAColor.subtleSurface).frame(height: 16)
                        RoundedRectangle(cornerRadius: 4).fill(LAAColor.subtleSurface).frame(width: 140, height: 12)
                    }
                }.padding(16).frame(minHeight: 64)
            }
        }.background(LAAColor.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("読み込み中").accessibilityIdentifier("work.loading")
    }
}
#endif
