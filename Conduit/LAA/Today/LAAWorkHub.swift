#if LAA_BUILD
import SwiftUI
import LAAKit

struct LAAWorkHub: View {
    let onRequestSettings: () -> Void
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.laaDesktop) private var laaDesktop
    @ObservedObject private var linkRequest = LAAWorkLinkRequest.shared
    @StateObject private var drafts = LAAWorkDrafts.makeStore()
    @EnvironmentObject private var usageState: LAAUsageState
    @EnvironmentObject private var decisions: LAADecisionBoard
    @State private var decisionSection: DecisionSection = .decisions
    @StateObject private var campaigns = LAACampaignBoard()
    @State private var section: Section = .projects
    @State private var showPairing = false
    @State private var showUsage = false
    @State private var createID = 0
    @State private var refreshID = 0
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.laaThemeID) private var themeID
    @Environment(\.laaPalette) private var palette
    @State private var linkedProject: String?

    /// Projects opens first: opening a project shows its requirements, done
    /// and under way, with its Sessions (owner, 2026-11-23; Sessions had
    /// opened first since 2026-11-11). The board stays beside Sessions, so
    /// what waits for the owner is one tap away.
    enum Section: String, CaseIterable, Identifiable {
        case projects, sessions, decisions, tasks
        var id: String { rawValue }
        var title: String {
            switch self {
            case .projects: String("Projects")
            case .sessions: String("Sessions")
            case .decisions: String("Decisions")
            case .tasks: String("Tasks")
            }
        }
        /// The board keeps its own list and pull to refresh; nothing to search.
        var searchable: Bool { self != .decisions }
    }

    enum DecisionSection: String, CaseIterable {
        case decisions, campaigns
        var title: String { self == .decisions ? Section.decisions.title : LAACampaignCopy.section }
    }

    private func select(_ value: Section) {
        guard value != section else { return }
        searchFocused = false
        search = ""
        section = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            LAAScreenHeader(title: "Work", identifier: "laa.work.title")
                .padding(.horizontal, LAASpacing.horizontal)
            LAAWorkSectionSelector(selection: Binding(get: { section }, set: select),
                                   decisions: decisions.count)
                .padding(.horizontal, LAASpacing.horizontal)
            if section == .decisions {
                Self.decisionPicker(selection: $decisionSection)
                    .padding(.horizontal, LAASpacing.horizontal)
            }
            if bridge.status != .paired { connectionState }
            else {
                if !laaDesktop && section.searchable {
                    // On the paper, not glass: with the top bar, the switcher
                    // and the tab bar the screen keeps three glass groups.
                    LAASearchField(placeholder: "Search", text: $search, identifier: "laa.work.search",
                                   focus: $searchFocused, glass: false)
                        .padding(.horizontal, LAASpacing.horizontal)
                        .id(section)
                }
                sectionContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, LAASpacing.x2)
        .laaTheme(themeID)
        .background(LAAColor.background.ignoresSafeArea()).foregroundStyle(LAAColor.text)
        .navigationTitle(Text(verbatim: "")).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let lowest = LAAUsageGauge.lowestWeeklyRemaining(usageState.usage.value ?? [])
                let usageLevel = LAAMeterLevel(remainingPercent: lowest)
                Button { showUsage = true } label: {
                    Image(systemName: LAAUsageGauge.symbol(lowest))
                        .foregroundStyle(usageLevel == .unknown ? LAAColor.secondaryText : palette.meter(usageLevel))
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(Text(verbatim: "Usage")).accessibilityIdentifier("work.usage")
                .accessibilityValue(Text(verbatim: lowest.map {
                    LAACopy.Usage.lowestWeekly + " " + $0.formatted(.number.precision(.fractionLength(0))) + "%"
                } ?? ""))
            }
            LAASettingsToolbar(action: onRequestSettings)
            // Separate item: a grouped toolbar control can collapse into a
            // menu on Catalyst, where the session stays open in its pane.
            if section == .projects && !laaDesktop {
                // New sits top right as an icon; the list starts under the search.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { createID += 1 } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New Project").accessibilityIdentifier("work.projects.new")
                        .disabled(bridge.status != .paired)
                }
            } else if section == .sessions {
                ToolbarItem(placement: .topBarTrailing) {
                    if laaDesktop {
                        Button { createID += 1 } label: { Label("New", systemImage: "plus") }
                            .accessibilityIdentifier("work.sessions.new")
                            .disabled(bridge.status != .paired)
                    } else {
                        Menu {
                            Button("New Session") { createID += 1 }.accessibilityIdentifier("work.sessions.new")
                        } label: { Image(systemName: "plus") }
                            .accessibilityLabel("New").accessibilityIdentifier("work.create")
                            .disabled(bridge.status != .paired)
                    }
                }
            } else if section == .tasks {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { createID += 1 } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Task").accessibilityIdentifier("work.linear.add")
                    .disabled(bridge.status != .paired)
                }
            }
        }
        .tint(LAAColor.link)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: linkRequest.generation, initial: true) { _, _ in
            guard linkRequest.url?.host == "work", linkRequest.claim("work.hub") != nil else { return }
            linkedProject = linkRequest.projectTarget
            if linkedProject != nil {
                section = .projects
            } else if linkRequest.decisionsLink {
                decisionSection = .decisions
                decisions.linkedID = linkRequest.decisionTarget
                select(.decisions)
            } else {
                select(linkRequest.sessionTarget == nil ? .tasks : .sessions)
            }
        }
        .onChange(of: bridge.revision) { _, _ in campaigns.reset() }
        .task(id: "campaigns|\(bridge.revision)|\(scenePhase == .active)|\(section)|\(decisionSection)") {
            guard scenePhase == .active, section == .decisions, decisionSection == .campaigns else { return }
            while !Task.isCancelled {
                await campaigns.refreshIfStale(bridge)
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        // The gauge reads Usage's last readings; opening Work refreshes them at
        // most once a minute (the same quiet interval as opening Usage).
        .task(id: bridge.revision) { await usageState.refreshOnTabOpen(bridge: bridge) }
        #if DEBUG
        .task { await debugLaunch() }
        #endif
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .navigationDestination(isPresented: $showUsage) {
            LAAUsageView(state: usageState)
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .projects:
            if laaDesktop { LAAWorkDesktopProjectsView(drafts: drafts, refreshID: refreshID, linkedProject: $linkedProject) }
            else {
                ScrollView {
                    LAAWorkProjectsSection(drafts: drafts, refreshID: refreshID, query: search, linkedProject: $linkedProject,
                                           createID: createID, onCreateConsumed: { createID = 0 })
                        .padding(.horizontal, LAASpacing.horizontal).padding(.bottom, LAASpacing.x8)
                }.refreshable { refreshID += 1 }
            }
        case .sessions:
            if laaDesktop { LAAWorkDesktopSessionsView(drafts: drafts, refreshID: refreshID, createID: createID, onCreateConsumed: { createID = 0 }) }
            else {
                ScrollView {
                    LAAWorkSessionsSection(drafts: drafts, refreshID: refreshID, query: search, createID: createID, onCreateConsumed: { createID = 0 })
                        .padding(.horizontal, LAASpacing.horizontal).padding(.bottom, LAASpacing.x8)
                }.refreshable { refreshID += 1; await decisions.load(bridge) }
            }
        case .decisions:
            switch decisionSection {
            case .decisions: LAADecisionBoardView(board: decisions, drafts: drafts)
            case .campaigns: LAACampaignBoardView(board: campaigns)
            }
        case .tasks: LAALinearTasksView(drafts: drafts, query: search, createID: createID, onCreateConsumed: { createID = 0 })
        }
    }

    static func decisionPicker(selection: Binding<DecisionSection>) -> some View {
        Menu {
            Picker("Decision Board", selection: selection) {
                ForEach(DecisionSection.allCases, id: \.self) { page in
                    Text(verbatim: page.title).tag(page)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label {
                Text(verbatim: selection.wrappedValue.title).laaTextStyle(.body)
            } icon: {
                Image(systemName: "chevron.down").accessibilityHidden(true)
            }
            .frame(minHeight: LAASpacing.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("work.decisions.sections")
    }

    #if DEBUG
    /// Window shots without typing (scripts/laa/mac-screens.sh):
    /// `-laa-work-section tasks` opens that section, and
    /// `-LAA_UI_TEST_PAIR_CODE <code>` pairs with the local fixture. Pairing
    /// only runs with `-LAA_UI_TEST_ISOLATED_BRIDGE`, whose Keychain entry is
    /// a fresh one per launch, so it never touches a real pairing.
    @MainActor private func debugLaunch() async {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if let raw = value("-laa-work-section") {
            if raw == DecisionSection.campaigns.rawValue {
                section = .decisions
                decisionSection = .campaigns
            } else if let wanted = Section(rawValue: raw) { section = wanted }
        }
        guard arguments.contains("-LAA_UI_TEST_ISOLATED_BRIDGE"), let code = value("-LAA_UI_TEST_PAIR_CODE"),
              bridge.status != .paired else { return }
        try? await bridge.pair(address: LAABridgeEndpoint.defaultAddress, code: code, name: "UI test")
    }
    #endif

    private var connectionState: some View {
        VStack(spacing: LAASpacing.x4) {
            Image(systemName: "desktopcomputer").font(.largeTitle).foregroundStyle(LAAColor.secondaryText)
            if bridge.status == .keychainError {
                Text(verbatim: "接続情報を読み取れません").fontWeight(.semibold)
                Text(verbatim: LAABridgeError.keychain.japaneseText)
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                Button { bridge.retryReadingCredentialsIfNeeded() } label: { Text(verbatim: "もう一度読み込む") }
                    .laaGlassButton(prominent: true)
                    .accessibilityIdentifier("work.retry-credentials")
            } else {
                Text(verbatim: "Macに接続してください").fontWeight(.semibold)
                Text(verbatim: bridge.status == .revoked ? LAABridgeError.revoked.japaneseText :
                     bridge.status == .unauthorized ? "この端末の接続を確認できません。もう一度接続してください。" :
                     "接続するとタスクやセッションを確認できます。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                Button { showPairing = true } label: { Text(verbatim: "Connect to Mac") }
                    .laaGlassButton(prominent: true)
                    .accessibilityIdentifier("work.connect")
            }
        }
        .padding(LAASpacing.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
#endif
