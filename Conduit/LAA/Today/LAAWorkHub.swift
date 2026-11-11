#if LAA_BUILD
import SwiftUI

struct LAAWorkHub: View {
    let onRequestSettings: () -> Void
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.laaDesktop) private var laaDesktop
    @ObservedObject private var linkRequest = LAAWorkLinkRequest.shared
    @StateObject private var drafts = LAAWorkDrafts.makeStore()
    @StateObject private var usageState = LAAUsageState()
    @StateObject private var decisions = LAADecisionBoard()
    @State private var section: Section = .sessions
    @State private var showPairing = false
    @State private var showUsage = false
    @State private var showNewProject = false
    @State private var createID = 0
    @State private var refreshID = 0
    @AppStorage("laa.work.decisionCount") private var decisionCount = 0
    @State private var search = ""
    @State private var decisionDevice: String?

    /// Sessions opens first; the board is the section beside it, so what waits
    /// for the owner is one tap away without pushing the lists down (owner,
    /// 2026-11-11).
    enum Section: String, CaseIterable, Identifiable {
        case sessions, decisions, tasks, routines
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sessions: String("Sessions")
            case .decisions: String("Decisions")
            case .tasks: String("Tasks")
            case .routines: String("Routines")
            }
        }
        /// The board keeps its own list and pull to refresh; nothing to search.
        var searchable: Bool { self != .decisions }
    }

    private func segmentTitle(_ value: Section) -> String {
        value == .decisions && decisions.count > 0 ? "\(value.title) \(decisions.count)" : value.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            LAAScreenHeader(title: "Work", identifier: "laa.work.title")
                .padding(.horizontal, LAASpacing.horizontal)
            LAASegmentedControl(values: Section.allCases, selection: $section, title: segmentTitle,
                                identifier: { "work.section.\($0.rawValue)" })
            .padding(.horizontal, LAASpacing.horizontal)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("work.segment")
            if bridge.status != .paired { connectionState }
            else {
                if !laaDesktop && section.searchable {
                    LAASearchField(placeholder: "検索", text: $search, identifier: "laa.work.search")
                        .padding(.horizontal, 20)
                }
                sectionContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, LAASpacing.x2)
        .background(LAAColor.background.ignoresSafeArea()).foregroundStyle(LAAColor.text)
        .navigationTitle(Text(verbatim: "")).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                let lowest = LAAUsageGauge.lowestWeeklyRemaining(usageState.usage.value ?? [])
                Button { showUsage = true } label: {
                    Image(systemName: LAAUsageGauge.symbol(lowest))
                        .foregroundStyle(lowest.map { LAAUsageMeterRule.needsAttention($0 / 100, countsDown: true) } == true
                                         ? LAAColor.attention : LAAColor.link)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                    .accessibilityLabel(Text(verbatim: "Usage")).accessibilityIdentifier("work.usage")
                    .accessibilityValue(Text(verbatim: lowest.map {
                        LAACopy.Usage.lowestWeekly + " " + $0.formatted(.number.precision(.fractionLength(0))) + "%"
                    } ?? LAACopy.notFetched))
                if section == .sessions {
                    Menu {
                        Button(String("新しいセッション")) { createID += 1 }.accessibilityIdentifier("work.sessions.new")
                        Button(String("新しいプロジェクト")) { showNewProject = true }.accessibilityIdentifier("work.projects.new")
                    } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .accessibilityLabel("作成").accessibilityIdentifier("work.create")
                    .disabled(bridge.status != .paired)
                } else if section != .decisions {
                    Button { if section == .routines { section = .tasks }; createID += 1 } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(String("新しいタスク")).accessibilityIdentifier("work.linear.add")
                    .disabled(bridge.status != .paired)
                }
            }
            LAASettingsToolbar(action: onRequestSettings)
        }
        .tint(LAAColor.link)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: section) { _, _ in search = "" }
        .onChange(of: linkRequest.generation, initial: true) { _, _ in
            guard linkRequest.url?.host == "work" else { return }
            if linkRequest.decisionsLink {
                decisions.linkedID = linkRequest.decisionTarget
                section = .decisions
            } else {
                section = linkRequest.sessionTarget == nil ? .tasks : .sessions
            }
        }
        .task(id: "\(bridge.revision)-\(scenePhase == .active)") {
            if decisionDevice != bridge.deviceID { decisions.reset(); decisionDevice = bridge.deviceID }
            if let cached = LAAWorkSessionCache.read([LAADecision].self, store: drafts, device: bridge.deviceID, target: "decisions") {
                decisions.restoreIfNeeded(cached)
            }
            await decisions.refreshIfStale(bridge)
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await decisions.refreshIfStale(bridge)
            }
        }
        // The gauge reads Usage's last readings; opening Work refreshes them at
        // most once a minute (the same quiet interval as opening Usage).
        .task(id: bridge.revision) { await usageState.refreshOnTabOpen(bridge: bridge) }
        .onChange(of: decisions.items) { _, items in
            LAAWorkSessionCache.save(items, store: drafts, device: bridge.deviceID, target: "decisions")
        }
        .onChange(of: decisions.count, initial: true) { _, count in decisionCount = count }
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .sheet(isPresented: $showNewProject) {
            LAAWorkProjectEditor(project: nil, canEditInstructions: true, drafts: drafts).environmentObject(bridge)
        }
        .navigationDestination(isPresented: $showUsage) {
            LAAUsageView(state: usageState, onRequestSettings: onRequestSettings)
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .sessions:
            if laaDesktop { LAAWorkDesktopSessionsView(drafts: drafts, refreshID: 0, createID: createID, onCreateConsumed: { createID = 0 }) }
            else {
                ScrollView {
                    LAAWorkSessionsSection(drafts: drafts, refreshID: refreshID, query: search, createID: createID, onCreateConsumed: { createID = 0 })
                        .padding(.horizontal, LAASpacing.horizontal).padding(.bottom, LAASpacing.x8)
                }.refreshable { refreshID += 1; await decisions.load(bridge) }
            }
        case .decisions: LAADecisionBoardView(board: decisions, drafts: drafts)
        case .tasks: LAALinearTasksView(drafts: drafts, query: search, createID: createID, onCreateConsumed: { createID = 0 })
        case .routines:
            if laaDesktop { LAAWorkDesktopCatalogView(kind: .routines) }
            else { LAAWorkCatalogView(kind: .routines, query: search) }
        }
    }

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
                Button { showPairing = true } label: { Text(verbatim: "Macに接続") }
                    .laaGlassButton(prominent: true)
                    .accessibilityIdentifier("work.connect")
            }
        }
        .padding(LAASpacing.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
#endif
