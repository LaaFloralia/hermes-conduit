#if LAA_BUILD
import SwiftUI

struct LAAWorkView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let onRequestSettings: () -> Void
    let embeddedSection: Int?
    /// The Work hub's search on the phone.
    let query: String

    init(embeddedSection: Int? = nil, onRequestSettings: @escaping () -> Void, query: String = "") {
        self.embeddedSection = embeddedSection
        self.onRequestSettings = onRequestSettings
        self.query = query
        _section = State(initialValue: embeddedSection ?? 0)
    }

    @StateObject private var drafts = LAAWorkDrafts.makeStore()
    @State private var section = 0
    @State private var projects: [LAAWorkProject] = []
    private let workspaces: [LAAWorkWorkspace] = []
    @State private var routines: [LAAWorkRoutine] = []
    @State private var projectInstructionsAvailable = false
    @State private var failure: String?
    @State private var isLoading = false
    @State private var showPairing = false
    @State private var showNewProject = false
    @State private var refreshID = 0
    @State private var loadID = UUID()

    var body: some View {
        ZStack {
            LAAColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x6) {
                    if embeddedSection == nil {
                        header
                        segmentPicker
                    }
                    if section == 2 {
                        LAAOwnerTasksView(drafts: drafts, refreshID: refreshID).environmentObject(bridge)
                    } else if bridge.status != .paired {
                        connection
                    } else {
                        content
                    }
                }
                .padding(.horizontal, LAASpacing.horizontal)
                .padding(.top, LAASpacing.x2)
                .padding(.bottom, LAASpacing.x8)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .laaTextStyle(.body).foregroundStyle(LAAColor.text)
            }
            .refreshable {
                if section == 3 { await load() } else { refreshID += 1 }
            }
        }
        .navigationTitle(Text(verbatim: embeddedSection == nil ? "" : "Work"))
        .navigationBarTitleDisplayMode(embeddedSection == nil ? .inline : .large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if embeddedSection == nil { LAASettingsButton(action: onRequestSettings) }
                else if section == 1 {
                    Button { showNewProject = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(Text(verbatim: "プロジェクトを追加"))
                        .disabled(bridge.status != .paired)
                }
            }
        }
        .tint(LAAColor.link)
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .sheet(isPresented: $showNewProject, onDismiss: { refreshID += 1 }) {
            LAAWorkProjectEditor(project: nil, canEditInstructions: true, drafts: drafts).environmentObject(bridge)
        }
        .onChange(of: embeddedSection) { _, value in if let value { section = value } }
        .task(id: "\(bridge.revision)-\(section)-\(refreshID)") { await load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: LAASpacing.x4) {
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                Text(verbatim: "LAA").laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.link)
                Text(verbatim: LAACopy.WorkTab.title).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("laa.work.title")
                Text(verbatim: LAACopy.WorkTab.subtitle).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            Spacer(minLength: LAASpacing.x2)
            if section == 1 {
                Button {
                    showNewProject = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(LAAColor.link)
                        .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                        .background(LAAColor.surface, in: Circle())
                        .overlay(Circle().stroke(LAAColor.separator))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: LAACopy.WorkTab.newProject))
                .accessibilityHint(Text(verbatim: bridge.status != .paired ? "Macへの接続が必要です。" : ""))
                .disabled(bridge.status != .paired)
            }
        }
    }

    private var segmentPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LAASpacing.x2) {
                ForEach(LAACopy.WorkTab.segments.indices, id: \.self) { index in
                    Button { section = index } label: {
                        Text(verbatim: LAACopy.WorkTab.segments[index])
                            .laaTextStyle(.secondary).fontWeight(section == index ? .semibold : .regular)
                            .foregroundStyle(section == index ? LAAColor.filledButtonText : LAAColor.secondaryText)
                            .padding(.horizontal, LAASpacing.x3)
                            .padding(.vertical, LAASpacing.x2)
                            .background(section == index ? LAAColor.filledButton : LAAColor.subtleSurface,
                                        in: RoundedRectangle(cornerRadius: LAARadius.selectionChip))
                            .frame(minHeight: LAASpacing.minimumTouchTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == index ? .isSelected : [])
                }
            }
        }
        .accessibilityIdentifier("work.segment")
    }

    private var routineList: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            if routines.isEmpty && !isLoading && failure == nil {
                Text(verbatim: "ルーティンはありません。").foregroundStyle(LAAColor.secondaryText)
            }
            ForEach(routines) { routine in
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    Text(verbatim: routine.name).fontWeight(.semibold)
                    Text(verbatim: "次回: " + (routine.nextRunAt.map { LAAWorkPresentation.date($0) } ?? "未確認"))
                    Text(verbatim: "前回: " + (routine.lastRunAt.map { LAAWorkPresentation.date($0) } ?? "未確認"))
                    Text(verbatim: "結果: " + (routine.result ?? "未確認"))
                }.laaTextStyle(.secondary).workCard()
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            if bridge.status == .keychainError {
                Label(LAAWorkPresentation.japanese("接続情報を読み取れません"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(LAAColor.attention)
                Text(verbatim: "右上の設定 > Mac から再ペアリングしてください。")
            } else {
                Label { Text(verbatim: "未接続") } icon: { Image(systemName: "circle") }
                    .foregroundStyle(LAAColor.secondaryText)
                Text(verbatim: bridge.status == .revoked || bridge.status == .unauthorized
                     ? "この端末の接続が無効です。新しいコードで接続してください。"
                     : "この端末はMacのLAA Bridgeとペアリングされていません。")
                Button(LAACopy.WorkTab.connect) { showPairing = true }
                    .buttonStyle(.borderedProminent).tint(LAAColor.filledButton)
                    .foregroundStyle(LAAColor.filledButtonText)
            }
        }
        .workCard()
    }

    @ViewBuilder private var content: some View {
        if let failure {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                Label(LAAWorkPresentation.japanese("取得できませんでした"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(LAAColor.attention)
                Text(verbatim: failure).foregroundStyle(LAAColor.text)
                Text(verbatim: "残っている一覧は前回取得した内容です。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                Button(LAACopy.WorkTab.retry) { Task { await load() } }
            }.workCard()
        }
        if isLoading { ProgressView().accessibilityLabel(Text(verbatim: "読み込み中")) }
        switch section {
        case 0: sessionList
        case 1: projectList
        default: routineList
        }
    }

    private var sessionList: some View {
        LAAWorkSessionsSection(drafts: drafts, refreshID: refreshID, query: query).environmentObject(bridge)
    }

    private var projectList: some View {
        LAAWorkProjectsSection(drafts: drafts, refreshID: refreshID, query: query).environmentObject(bridge)
    }

    @MainActor private func load() async {
        let id = UUID()
        loadID = id
        let selected = section
        guard bridge.status == .paired, selected != 2 else { isLoading = false; failure = nil; return }
        isLoading = true
        failure = nil
        defer { if loadID == id { isLoading = false } }
        do {
            if selected == 0 || selected == 1 {
                let projectPage: [LAAWorkProject] = try await loadItems("/v1/projects")
                guard !Task.isCancelled, loadID == id else { return }
                projects = projectPage
                if let first = projectPage.first {
                    let detail: LAAWorkProject? = try? await bridge.read("/v1/projects/\(first.id)")
                    guard !Task.isCancelled, loadID == id else { return }
                    projectInstructionsAvailable = detail?.hasInstructionBody == true && detail?.instructionError == nil
                } else { projectInstructionsAvailable = false }
            } else if selected == 3 {
                let page: LAAWorkPage<LAAWorkRoutine> = try await bridge.read("/v1/routines")
                if !Task.isCancelled && loadID == id { routines = page.items }
            }
        } catch is CancellationError {
            return
        } catch let error as LAABridgeError {
            if !Task.isCancelled && loadID == id { failure = error.japaneseText }
        } catch {
            if !Task.isCancelled && loadID == id { failure = "Macからの応答を読み取れませんでした。" }
        }
    }

    @MainActor private func loadItems<T: Decodable>(_ path: String) async throws -> [T] {
        var all: [T] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let query = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
            let page: LAAWorkPage<T> = try await bridge.read(LAAWorkPresentation.path(path, query: query))
            all.append(contentsOf: page.items)
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw LAABridgeError.invalidResponse }
        } while cursor != nil && seen.count < 50
        guard cursor == nil else { throw LAABridgeError.invalidResponse }
        return all
    }
}

private struct LAAWorkCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(LAASpacing.x4).frame(maxWidth: .infinity, alignment: .leading)
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            .laaTextStyle(.body).foregroundStyle(LAAColor.text)
    }
}
private struct LAAWorkListRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, LAASpacing.x4)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .overlay(alignment: .bottom) { Divider().overlay(LAAColor.separator) }
            .contentShape(Rectangle())
    }
}
extension View {
    func workCard() -> some View { modifier(LAAWorkCard()) }
    func workListRow() -> some View { modifier(LAAWorkListRow()) }
}
#endif
