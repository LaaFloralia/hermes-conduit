#if LAA_BUILD
import SwiftUI

struct LAAWorkHub: View {
    let onRequestSettings: () -> Void
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var drafts = LAAWorkDrafts.makeStore()
    @State private var section: Section = .priority
    @State private var showPairing = false

    enum Section: String, CaseIterable, Identifiable {
        case priority, tasks, sessions, projects, routines, skills
        var id: String { rawValue }
        var title: String {
            switch self {
            case .priority: AppLocalization.string("Work priorities")
            case .tasks: AppLocalization.string("Tasks")
            case .sessions: AppLocalization.string("Sessions")
            case .projects: AppLocalization.string("Projects")
            case .routines: AppLocalization.string("Work routines")
            case .skills: AppLocalization.string("Skills")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LAASpacing.x2) {
                        ForEach(Section.allCases) { value in
                            pill(value).id(value)
                        }
                    }
                    .padding(.horizontal, LAASpacing.horizontal)
                    .padding(.vertical, LAASpacing.x2)
                }
                .onChange(of: section) { _, value in withAnimation { proxy.scrollTo(value, anchor: .center) } }
            }
            .accessibilityIdentifier("work.segment")
            if bridge.status != .paired {
                VStack(spacing: LAASpacing.x4) {
                    Image(systemName: "desktopcomputer").font(.largeTitle).foregroundStyle(LAAColor.secondaryText)
                    Text(verbatim: "Macに接続してください").fontWeight(.semibold)
                    Text(verbatim: "接続するとタスクやセッションを確認できます。")
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    Button { showPairing = true } label: { Text(verbatim: "Macに接続") }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("work.connect")
                }
                .padding(LAASpacing.horizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch section {
                case .priority, .tasks:
                    LAALinearTasksView(drafts: drafts, priorityOnly: section == .priority)
                case .sessions: LAAWorkView(embeddedSection: 0, onRequestSettings: onRequestSettings)
                case .projects: LAAWorkView(embeddedSection: 1, onRequestSettings: onRequestSettings)
                case .routines: LAAWorkCatalogView(kind: .routines).id(section)
                case .skills: LAAWorkCatalogView(kind: .skills).id(section)
                }
            }
        }
        .background(LAAColor.background.ignoresSafeArea())
        .foregroundStyle(LAAColor.text)
        .navigationTitle(Text(verbatim: "Work"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { LAASettingsButton(action: onRequestSettings) }
        }
        .tint(LAAColor.link)
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
    }

    @ViewBuilder private func pill(_ value: Section) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            pillButton(value)
                .glassEffect(.regular.tint(value == section ? LAAColor.selectionFill : .clear).interactive(), in: .capsule)
        } else {
            pillButton(value)
                .background(value == section ? LAAColor.selectionFill : LAAColor.surface, in: Capsule())
        }
    }

    private func pillButton(_ value: Section) -> some View {
        Button { section = value } label: {
            Text(verbatim: value.title)
                .laaTextStyle(.secondary)
                .fontWeight(value == section ? .semibold : .regular)
                .foregroundStyle(value == section ? LAAColor.link : LAAColor.secondaryText)
                .padding(.horizontal, LAASpacing.x4)
                .frame(minHeight: LAASpacing.minimumTouchTarget)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(value == section ? .isSelected : [])
        .accessibilityIdentifier("work.section.\(value.rawValue)")
    }
}
#endif
