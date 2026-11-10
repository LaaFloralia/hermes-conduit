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
                HStack {
                    Text(verbatim: "判断待ち").font(.system(size: 15, weight: .semibold))
                        .accessibilityIdentifier("work.decisions.summary")
                    Spacer()
                    Text(verbatim: String(board.items.count))
                        .font(.custom("Georgia", size: 20, relativeTo: .title3))
                        .foregroundStyle(LAAColor.attention)
                }.padding(.horizontal, 12)
                VStack(spacing: 0) {
                    ForEach(Array(board.items.prefix(3))) { item in
                        Button { selected = item } label: {
                            HStack(spacing: 12) {
                                Circle().fill(LAAColor.attention).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: item.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                                    let elapsed = item.createdAt.flatMap(LAAWorkSessionStyle.relative)
                                    let detail = [item.sourceLine, elapsed].compactMap { $0 }.joined(separator: " · ")
                                    if !detail.isEmpty {
                                        Text(verbatim: detail).laaTextStyle(.secondary)
                                            .foregroundStyle(LAAColor.secondaryText).lineLimit(1)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(12).frame(minHeight: 64).contentShape(Rectangle())
                        }.buttonStyle(LAAListRowStyle()).accessibilityIdentifier("work.decision.\(item.id)")
                    }
                }
                if board.items.count > 3 {
                    Button(String("すべて表示")) { showAll = true }.frame(minHeight: 44).accessibilityIdentifier("work.decisions.all")
                }
            }.padding(12).background(LAAColor.surface, in: RoundedRectangle(cornerRadius: 16))
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

#endif
