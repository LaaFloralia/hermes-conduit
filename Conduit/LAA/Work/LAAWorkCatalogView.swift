#if LAA_BUILD
import SwiftUI

struct LAAWorkSkill: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let source: String
    let category: String?
    let summary: String?
    let detail: String?
    /// The short number the owner says ("K3"). Absent from an older Bridge.
    let ref: String?

    var group: String { category ?? "その他" }
    var explanation: String { summary ?? description }
}

struct LAAWorkCatalogView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @StateObject private var cache: ComposerDraftStore

    @MainActor init() {
        _cache = StateObject(wrappedValue: LAAWorkDrafts.makeStore(fileURL: LAAWorkDrafts.fileURL.deletingLastPathComponent().appendingPathComponent("catalog-skills-cache-v1.json")))
    }
    @State private var skills: [LAAWorkSkill] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var failed = false
    @State private var loadID = UUID()
    @State private var deviceID: String?
    @State private var retryTask: Task<Void, Never>?
    @State private var retryToken = UUID()

    var body: some View {
        List {
            if failed {
                LAAWorkFailure(text: "一覧が応答しません。Macとの接続を確認してください。") { Task { await load() } }
            }
            if loading && !loaded { LAALoadingDots().listRowBackground(Color.clear) }
            ForEach(skillGroups, id: \.self) { category in
                Section {
                    ForEach(displayedSkills.filter { $0.group == category }) { skill in
                        NavigationLink {
                            LAAWorkSkillDetail(skill: skill)
                        } label: {
                            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                                HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                                    LAAWorkRefLabel(ref: skill.ref)
                                    Text(verbatim: skill.name).fontWeight(.medium)
                                }
                                Text(verbatim: skill.explanation.isEmpty ? "No Description" : skill.explanation)
                                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(2)
                            }.padding(.vertical, LAASpacing.x2)
                        }.listRowBackground(LAAColor.surface)
                    }
                } header: { Text(verbatim: category) }
            }
            if loaded && !loading && !failed && displayedSkills.isEmpty {
                ContentUnavailableView {
                    Label { Text(verbatim: "No Skills") }
                    icon: { Image(systemName: "sparkles") }
                }.listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped).textCase(nil)
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
        .task(id: bridge.revision) { await load() }
        .onDisappear { retryTask?.cancel(); retryTask = nil }
    }

    private var displayedSkills: [LAAWorkSkill] {
        var names = Set<String>()
        return skills.filter { names.insert($0.name).inserted }.sorted { $0.name < $1.name }
    }

    private var skillGroups: [String] {
        let order = ["日常業務", "調査・要約", "トレード", "経理・会計", "発信・営業", "デザイン・資料", "動画・音声", "開発・運用", "その他"]
        return Set(displayedSkills.map(\.group)).sorted {
            let a = order.firstIndex(of: $0) ?? order.count
            let b = order.firstIndex(of: $1) ?? order.count
            return a == b ? $0 < $1 : a < b
        }
    }

    private func load() async {
        retryTask?.cancel(); retryTask = nil
        if await readList(), !loaded { scheduleRetry() }
    }

    /// Returns true for a failed read of the current list, not for cancellation.
    private func readList() async -> Bool {
        let epoch = UUID(); loadID = epoch
        let device = bridge.deviceID
        if device != deviceID {
            skills = LAAWorkSessionCache.read([LAAWorkSkill].self, store: cache, device: device, target: "skills") ?? []
            loaded = !skills.isEmpty
            deviceID = device
        }
        guard bridge.status == .paired else { return false }
        loading = true; failed = false
        defer { if loadID == epoch { loading = false } }
        do {
            let page: LAAWorkPage<LAAWorkSkill> = try await bridge.read("/v1/skills")
            guard loadID == epoch, device == bridge.deviceID, !Task.isCancelled else { return false }
            guard page.nextCursor == nil else { throw LAABridgeError.invalidResponse }
            skills = page.items
            LAAWorkSessionCache.save(skills, store: cache, device: device, target: "skills")
            loaded = true
            return false
        } catch is CancellationError {
            return false
        } catch {
            guard loadID == epoch, device == bridge.deviceID, !Task.isCancelled else { return false }
            failed = true
            return true
        }
    }

    /// Retry a cold read twice; stop on success or when the view leaves.
    private func scheduleRetry() {
        retryTask?.cancel()
        let token = UUID(); retryToken = token
        retryTask = Task {
            for seconds in [2.0, 6.0] {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, retryToken == token, !loaded else { return }
                guard await readList() else { return }
                guard !Task.isCancelled, retryToken == token else { return }
            }
        }
    }
}

private struct LAAWorkSkillDetail: View {
    let skill: LAAWorkSkill
    var body: some View {
        List {
            Section {
                LAAWorkRefLabel(ref: skill.ref)
                Text(verbatim: skill.explanation.isEmpty ? "No Description" : skill.explanation).fontWeight(.medium)
                if let detail = skill.detail, !detail.isEmpty, detail != skill.explanation { Text(verbatim: detail) }
            } header: { Text(verbatim: skill.group) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(verbatim: skill.name))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("work.skill.detail")
    }
}

#endif
