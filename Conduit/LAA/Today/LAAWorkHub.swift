#if LAA_BUILD
import SwiftUI

struct LAAWorkHub: View {
    let onRequestSettings: () -> Void
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.laaDesktop) private var laaDesktop
    @ObservedObject private var linkRequest = LAAWorkLinkRequest.shared
    @StateObject private var drafts = LAAWorkDrafts.makeStore()
    // The Usage tab keeps its own state: Work opens it rarely, and the screen
    // refreshes on appear. The shell's instance keeps the main Usage tab.
    @StateObject private var usageState = LAAUsageState()
    @State private var section: Section = .priority
    @State private var showPairing = false

    enum Section: String, CaseIterable, Identifiable {
        case priority, tasks, sessions, projects, routines, skills, usage
        var id: String { rawValue }
        var title: String {
            switch self {
            case .priority: AppLocalization.string("Work priorities")
            case .tasks: AppLocalization.string("Tasks")
            case .sessions: AppLocalization.string("Sessions")
            case .projects: AppLocalization.string("Projects")
            case .routines: AppLocalization.string("Work routines")
            case .skills: AppLocalization.string("Skills")
            case .usage: AppLocalization.string("AI usage")
            }
        }
        var desktopTitle: String {
            switch self {
            case .priority: AppLocalization.string("Priority")
            case .tasks: AppLocalization.string("Tasks")
            case .sessions: AppLocalization.string("Sessions")
            case .projects: AppLocalization.string("Projects")
            case .routines: AppLocalization.string("Routines")
            case .skills: AppLocalization.string("Skills")
            case .usage: AppLocalization.string("AI usage")
            }
        }
    }

    var body: some View {
        Group {
            if laaDesktop { desktopBody } else { phoneBody }
        }
        .onChange(of: linkRequest.generation, initial: true) { _, _ in
            let url = linkRequest.url
            if url?.host == "work" { section = linkRequest.sessionTarget == nil ? .tasks : .sessions }
        }
        .background(LAAColor.background.ignoresSafeArea())
        .foregroundStyle(LAAColor.text)
        .navigationTitle(Text(verbatim: laaDesktop ? "" : "Work"))
        .navigationBarTitleDisplayMode(laaDesktop ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { LAASettingsButton(action: onRequestSettings) }
        }
        .tint(LAAColor.link)
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
    }

    private var phoneBody: some View {
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
                connectionState
            } else {
                switch section {
                case .priority, .tasks:
                    LAALinearTasksView(drafts: drafts, priorityOnly: section == .priority)
                case .sessions: LAAWorkView(embeddedSection: 0, onRequestSettings: onRequestSettings)
                case .projects: LAAWorkView(embeddedSection: 1, onRequestSettings: onRequestSettings)
                case .routines: LAAWorkCatalogView(kind: .routines).id(section)
                case .skills: LAAWorkCatalogView(kind: .skills).id(section)
                case .usage: LAAUsageView(state: usageState, onRequestSettings: onRequestSettings)
                }
            }
        }
    }

    private var desktopBody: some View {
        VStack(spacing: 0) {
            desktopHeader
            Rectangle().fill(LAAColor.separator).frame(height: 1)
            if bridge.status != .paired {
                connectionState
            } else {
                desktopSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var desktopHeader: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "LAA").laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.link)
                    Text(verbatim: LAACopy.WorkTab.title).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: LAACopy.WorkTab.subtitle).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
                Spacer(minLength: LAASpacing.x4)
            }
            HStack(spacing: 0) {
                ForEach(Section.allCases) { value in
                    Button { section = value } label: {
                        Text(verbatim: value.desktopTitle)
                            .laaTextStyle(.secondary)
                            .fontWeight(value == section ? .semibold : .regular)
                            .foregroundStyle(value == section ? LAAColor.filledButtonText : LAAColor.secondaryText)
                            .padding(.horizontal, LAASpacing.x3)
                            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget)
                            .background(value == section ? LAAColor.filledButton : .clear,
                                        in: RoundedRectangle(cornerRadius: LAARadius.selectionChip))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(value == section ? .isSelected : [])
                    .accessibilityIdentifier("work.section.\(value.rawValue)")
                }
            }
            .padding(3)
            .frame(maxWidth: 760)
            .background(LAAColor.subtleSurface, in: RoundedRectangle(cornerRadius: LAARadius.selectionChip + 3))
            .accessibilityIdentifier("work.segment")
        }
        .padding(.horizontal, LAASpacing.x6)
        .padding(.top, LAASpacing.x4)
        .padding(.bottom, LAASpacing.x3)
    }

    @ViewBuilder private var desktopSection: some View {
        switch section {
        case .priority: LAALinearTasksView(drafts: drafts, priorityOnly: true)
        case .tasks: LAALinearTasksView(drafts: drafts, priorityOnly: false)
        case .sessions: LAAWorkDesktopSessionsView(drafts: drafts, refreshID: 0)
        case .projects: LAAWorkDesktopProjectsView(drafts: drafts, refreshID: 0)
        case .routines: LAAWorkDesktopCatalogView(kind: .routines)
        case .skills: LAAWorkDesktopCatalogView(kind: .skills)
        case .usage: LAAUsageView(state: usageState, onRequestSettings: onRequestSettings)
        }
    }

    private var connectionState: some View {
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
