#if LAA_BUILD
import SwiftUI

private struct LAAStudioWorkItem: Identifiable {
    let id: String
    let name: String
    let kind: String
    let media: String?
    let poster: String?
    let usdz: String?
    let preparing: Bool
    let unavailable: String?
    let previewOnly: Bool
    let target: LAAStudioReview.Target?
    let revision: Int
    let bytes: Int64?
    let createdAt: String?
    var symbol: String {
        switch kind {
        case "page", "pdf": return "doc.richtext"
        case "image": return "photo"
        case "video": return "play.rectangle"
        case "audio": return "waveform"
        case "model": return "cube"
        default: return "doc"
        }
    }
    var thumbnail: String? { poster ?? (["page", "image"].contains(kind) ? media : nil) }
}

private enum LAAStudioFilter: String, CaseIterable, Identifiable {
    case all = "すべて", pages = "ページ", images = "画像", video = "動画", model = "3D", audio = "音声"
    var id: String { rawValue }
    func includes(_ item: LAAStudioWorkItem) -> Bool {
        switch self {
        case .all: return true
        case .pages: return item.kind == "page"
        case .images: return item.kind == "image"
        case .video: return item.kind == "video"
        case .model: return item.kind == "model"
        case .audio: return item.kind == "audio"
        }
    }
}

struct LAAStudioWorkBody: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.laaDesktop) private var laaDesktop
    let project: LAAStudioProject
    let snapshot: LAAStudioSnapshot?
    @State private var fetchedSnapshot: LAAStudioSnapshot?
    @State private var detail: LAAStudioProjectDetail?
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @State private var filter = LAAStudioFilter.all
    @State private var displacedDrafts: [LAAStudioReviewStore.DisplacedDraft] = []
    @State private var draftStorageError = false
    private var activeSnapshot: LAAStudioSnapshot? { snapshot ?? fetchedSnapshot }
    private var current: LAAStudioProject { detail?.project ?? project }
    private var driveURL: String? { detail == nil ? current.driveUrl : detail?.delivery?.driveUrl }
    private var deliveredRevision: Int? { detail == nil ? current.deliveredRevision : detail?.delivery?.revision }
    private var items: [LAAStudioWorkItem] {
        allItems.filter { filter.includes($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }
    private var versions: [LAAStudioWorkItem] {
        (detail?.versions ?? []).map { version in
            LAAStudioWorkItem(id: "version:\(version.id)", name: version.name, kind: version.kind, media: version.media,
                              poster: version.poster, usdz: version.usdz, preparing: version.preparing == true,
                              unavailable: version.unavailable, previewOnly: version.previewOnly == true,
                              target: .version(version.id), revision: version.revision,
                              bytes: version.bytes, createdAt: version.createdAt)
        }
    }
    @State private var selectedItem = ""
    @State private var revising = false
    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                if !gallery.isEmpty {
                    LAAStudioGallery(items: gallery, selection: $selectedItem, driveURL: driveURL).id("gallery")
                }
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    Text(verbatim: current.title).font(.custom("Georgia", size: 22, relativeTo: .title2)).foregroundStyle(LAAColor.text)
                    Text(verbatim: summary)
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
                if let error { LAAStudioConnectionLine(message: error) { Task { await load() } } }
                if activeSnapshot?.supportsV2 == true {
                    HStack(spacing: LAASpacing.x3) {
                        LAAStudioAdoptButton(project: current, reviews: detail?.reviews ?? [])
                        Button("直しを頼む") { revising = true }.laaGlassButton(prominent: true)
                            .accessibilityIdentifier("laa.studio.revise")
                    }
                }
                if !versions.isEmpty || LAAStudioMedia.driveURL(driveURL) != nil {
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        Text("納品").font(.footnote.weight(.semibold)).foregroundStyle(LAAColor.secondaryText)
                        ForEach(versions) { item in
                            NavigationLink { LAAStudioItemView(items: versions, startIndex: versions.firstIndex { $0.id == item.id } ?? 0,
                                project: current, snapshot: activeSnapshot, reviews: detail?.reviews ?? [], driveURL: driveURL, allowsReview: detail != nil) } label: {
                                Label(item.name, systemImage: item.symbol).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            }
                        }
                        if let url = LAAStudioMedia.driveURL(driveURL) {
                            ShareLink("共有", item: url).frame(minHeight: 44)
                            Link("Driveで開く", destination: url).frame(minHeight: 44)
                        }
                    }
                }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        HStack {
                            Text("ページと素材").font(.footnote.weight(.semibold)).foregroundStyle(LAAColor.secondaryText)
                            Spacer()
                            if Set(allItems.map(\.kind)).count > 1 {
                                Menu {
                                    Picker("種類", selection: $filter) {
                                        ForEach(LAAStudioFilter.allCases) { Text(verbatim: $0.rawValue).tag($0) }
                                    }
                                } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44) }.accessibilityLabel("種類")
                            }
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: LAASpacing.x2), count: 3), spacing: LAASpacing.x3) {
                            ForEach(items) { item in
                                Group {
                                    if gallery.contains(where: { $0.id == item.id }) {
                                        Button { selectedItem = item.id; scroll.scrollTo("gallery", anchor: .top) } label: { itemLabel(item) }
                                    } else {
                                        NavigationLink { LAAStudioItemView(items: items, startIndex: items.firstIndex { $0.id == item.id } ?? 0,
                                            project: current, snapshot: activeSnapshot, reviews: detail?.reviews ?? [], driveURL: driveURL, allowsReview: detail != nil) } label: { itemLabel(item) }
                                    }
                                }.buttonStyle(.plain).accessibilityIdentifier("laa.studio.item.\(item.id)")

                            }
                        }
                    }
                }
                if !displacedDrafts.isEmpty, let snapshot = activeSnapshot {
                    ForEach(displacedDrafts) { draft in
                        NavigationLink("保存した講評の下書き") {
                            LAAStudioReviewView(snapshot: snapshot, project: current, target: draft.target,
                                targetName: draft.targetName ?? "保存した版", revision: draft.revision ?? current.revision,
                                reviews: detail?.reviews ?? [], unavailableInListing: true)
                        }.frame(minHeight: 44).accessibilityIdentifier("laa.studio.displaced.\(draft.id)")
                    }
                }
            }.padding(LAASpacing.horizontal).laaPageWidth()
        }.background(LAAColor.background.ignoresSafeArea()).navigationTitle("作品")
            .tint(LAAColor.link).navigationBarTitleDisplayMode(.inline)
            .task(id: bridge.revision) {
                detail = LAAStudioCache.load(LAAStudioProjectDetail.self, scope: LAAStudioCache.scope(bridge), item: project.id)
                await load()
            }.refreshable { await load() }
            .sheet(isPresented: $revising, onDismiss: { Task { await load() } }) {
                if let snapshot = activeSnapshot {
                    NavigationStack {
                        LAAStudioCreateView(snapshot: snapshot, initialProject: current, draftID: current.id)
                    }.environmentObject(bridge)
                }
            }
        }
    }
    private func itemLabel(_ item: LAAStudioWorkItem) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            LAAStudioThumbnail(path: item.thumbnail, symbol: item.symbol).aspectRatio(1, contentMode: .fit)
            Text(verbatim: item.name).laaTextStyle(.secondary).lineLimit(2).foregroundStyle(LAAColor.text)
        }
    }
    private var summary: String {
        let count = current.pages.isEmpty ? "\(current.assets?.count ?? 0)点" : "\(current.pages.count)ページ"
        let time = LAAStudioPresentation.relativeDate(current.syncedAt)
        return time.isEmpty ? count : count + " · " + time
    }
    private var allItems: [LAAStudioWorkItem] {
        return current.pages.map { page in
            LAAStudioWorkItem(id: "page:\(page.id)", name: page.name, kind: "page", media: page.preview,
                poster: nil, usdz: nil, preparing: false, unavailable: nil, previewOnly: false,
                target: .page(page.id), revision: current.revision, bytes: nil, createdAt: nil)
        } + (current.assets ?? []).map { asset in
            LAAStudioWorkItem(id: "asset:\(asset.id)", name: asset.name, kind: asset.kind, media: asset.url,
                poster: asset.poster, usdz: asset.usdz, preparing: asset.preparing == true,
                unavailable: asset.unavailable, previewOnly: asset.previewOnly == true, target: nil,
                revision: current.revision, bytes: nil, createdAt: nil)
        }
    }
    private var gallery: [LAAStudioWorkItem] {
        let content = allItems + versions.filter { $0.revision == current.revision }
        return content.filter { ["page", "image", "video", "pdf"].contains($0.kind) }
    }
    @MainActor private func load() async {
        guard !loading, LAAStudioData.available(bridge) else { return }
        loading = true; error = nil
        defer { loading = false }
        let revision = bridge.revision
        do {
            if snapshot == nil {
                let result = try await LAAStudioData.snapshot(bridge)
                guard revision == bridge.revision else { return }; fetchedSnapshot = result
            }
            guard activeSnapshot?.supportsV2 == true else { detail = nil; return }
            let result = try await LAAStudioData.project(project.id, bridge: bridge)
            guard revision == bridge.revision else { return }; detail = result
            LAAStudioCache.save(result, scope: LAAStudioCache.scope(bridge), item: project.id)
            refreshDisplacedDrafts()
        } catch is CancellationError { }
        catch { if revision == bridge.revision { self.error = LAAStudioData.message(error) } }
    }
    @MainActor private func refreshDisplacedDrafts() {
        guard let detail, let deviceID = bridge.deviceID else { displacedDrafts = []; return }
        draftStorageError = false
        for version in detail.versions {
            if !LAAStudioReviewStore.upgradeLegacy(deviceID: deviceID, projectID: project.id, target: .version(version.id),
                                                   targetName: version.name, revision: version.revision) { draftStorageError = true }
        }
        displacedDrafts = LAAStudioReviewStore.displaced(deviceID: deviceID, projectID: project.id,
                                                        listedVersionIDs: Set(detail.versions.map(\.id)))
    }
}

private struct LAAStudioGallery: View {
    let items: [LAAStudioWorkItem]
    @Binding var selection: String
    let driveURL: String?
    var body: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                Group {
                    if item.kind == "video", item.id == selection,
                       let path = LAAStudioMedia.bridgePath(item.media, allowed: ["mp4"]) {
                        LAAStudioPlayerView(asset: .init(id: item.id, name: item.name, kind: "video", url: item.media,
                            poster: item.poster, unavailable: item.unavailable, previewOnly: item.previewOnly), path: path)
                    } else if item.preparing {
                        Text("閲覧用コピーを準備中").foregroundStyle(LAAColor.secondaryText)
                    } else if let unavailable = item.unavailable {
                        Text(verbatim: unavailable).foregroundStyle(LAAColor.secondaryText)
                    } else if item.kind == "pdf" {
                        LAAStudioFilePreview(path: item.media, driveURL: driveURL)
                    } else {
                        LAAStudioThumbnail(path: item.thumbnail, symbol: item.symbol)
                    }
                }.tag(item.id).padding(.bottom, items.count > 1 ? LAASpacing.x6 : 0)
                    .accessibilityLabel(item.name)
            }
        }.tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
            .frame(height: 350).background(LAAColor.subtleSurface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            .accessibilityIdentifier("laa.studio.gallery")
            .onAppear { if selection.isEmpty { selection = items.first?.id ?? "" } }
            .onChange(of: items.map(\.id)) { _, ids in if !ids.contains(selection) { selection = ids.first ?? "" } }
    }
}

private struct LAAStudioItemView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let items: [LAAStudioWorkItem]
    let project: LAAStudioProject
    let snapshot: LAAStudioSnapshot?
    let driveURL: String?
    let allowsReview: Bool
    @State private var revising = false
    @State private var index: Int
    @State private var reviews: [LAAStudioReview]
    init(items: [LAAStudioWorkItem], startIndex: Int, project: LAAStudioProject,
         snapshot: LAAStudioSnapshot?, reviews: [LAAStudioReview], driveURL: String?, allowsReview: Bool) {
        self.items = items; self.project = project; self.snapshot = snapshot
        self.driveURL = driveURL; self.allowsReview = allowsReview; _index = State(initialValue: startIndex)
        _reviews = State(initialValue: reviews)
    }
    private var item: LAAStudioWorkItem { items[index] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                HStack {
                    Button { index -= 1 } label: { Label { Text(verbatim: "前へ") } icon: { Image(systemName: "chevron.left") }.frame(minHeight: LAASpacing.minimumTouchTarget) }.disabled(index == 0)
                    Spacer()
                    Text(verbatim: "\(index + 1) / \(items.count)").laaTextStyle(.secondary)
                    Spacer()
                    Button { index += 1 } label: { Label { Text(verbatim: "次へ") } icon: { Image(systemName: "chevron.right") }.frame(minHeight: LAASpacing.minimumTouchTarget) }.disabled(index + 1 == items.count)
                }
                Text(verbatim: item.name).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                Text(verbatim: "\(item.kind.capitalized) · Revision \(item.revision)").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                if let bytes = item.bytes {
                    Text(verbatim: "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) · \(LAAWorkPresentation.date(item.createdAt))")
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
                if item.previewOnly { Text(verbatim: "閲覧用コピー").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
                if item.preparing { Text(verbatim: "閲覧用コピーを準備中です。時間をおいて作品を更新してください。").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
                content.id(item.id)
                if allowsReview, let snapshot, snapshot.supportsV2 {
                    Button("直しを頼む") { revising = true }.laaGlassButton(prominent: true)
                }
            }.padding(LAASpacing.horizontal).laaPageWidth()
        }.background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: "閲覧"))
            .navigationBarTitleDisplayMode(.inline).tint(LAAColor.link)
            .sheet(isPresented: $revising) {
                if let snapshot {
                    NavigationStack { LAAStudioCreateView(snapshot: snapshot, initialProject: project,
                        initialPrompt: "「" + item.name + "」の直し: ", draftID: project.id) }.environmentObject(bridge)
                }
            }
            .onAppear {
                guard allowsReview else { return }
                Task { if let detail = try? await LAAStudioData.project(project.id, bridge: bridge) { reviews = detail.reviews } }
            }
    }
    @ViewBuilder private var content: some View {
        if item.unavailable == nil && ["page", "image", "pdf"].contains(item.kind),
           LAAStudioMedia.bridgePath(item.media, allowed: item.kind == "pdf" ? ["pdf"] : ["jpg", "png", "webp"]) != nil {
            LAAStudioFilePreview(path: item.media, driveURL: driveURL)
        } else if item.unavailable == nil && item.kind == "model", LAAStudioMedia.bridgePath(item.usdz, allowed: ["usdz"]) != nil {
            LAAStudioFilePreview(path: item.usdz, driveURL: driveURL)
        } else if item.unavailable == nil && ["video", "audio"].contains(item.kind),
                  let path = LAAStudioMedia.bridgePath(item.media, allowed: item.kind == "video" ? ["mp4"] : ["mp3"]) {
            LAAStudioPlayerView(asset: .init(id: item.id, name: item.name, kind: item.kind, url: item.media,
                                             poster: item.poster, unavailable: nil, previewOnly: item.previewOnly), path: path)
        } else {
            Text(verbatim: reason).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            if let url = LAAStudioMedia.driveURL(driveURL) {
                Link(destination: url) { Label { Text(verbatim: "Driveで開く") } icon: { Image(systemName: "arrow.up.right.square") }.frame(minHeight: LAASpacing.minimumTouchTarget) }
            }
        }
    }
    private var reason: String {
        if item.preparing { return "閲覧用コピーができるまでお待ちください。" }
        switch item.unavailable {
        case "too_large": return "サイズまたは長さが上限を超えています。"
        case "unsupported_format": return "この形式はアプリで閲覧できません。"
        case "conversion_failed": return "閲覧用コピーを作成できませんでした。"
        case "source_unreadable": return "元のファイルを読み取れませんでした。"
        default: return item.kind == "model" ? "この3Dはアプリで閲覧できません。" : LAACopy.Studio.unsupported
        }
    }
}
#endif
