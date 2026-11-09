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
    case all = "All", pages = "Pages", images = "Images", video = "Video", model = "3D", audio = "Audio"
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
        let pages = current.pages.map { page in
            LAAStudioWorkItem(id: "page:\(page.id)", name: page.name, kind: "page", media: page.preview,
                              poster: nil, usdz: nil, preparing: false, unavailable: nil, previewOnly: false,
                              target: .page(page.id), revision: current.revision, bytes: nil, createdAt: nil)
        }
        let assets = (current.assets ?? []).map { asset in
            LAAStudioWorkItem(id: "asset:\(asset.id)", name: asset.name, kind: asset.kind, media: asset.url,
                              poster: asset.poster, usdz: asset.usdz, preparing: asset.preparing == true,
                              unavailable: asset.unavailable, previewOnly: asset.previewOnly == true,
                              target: nil, revision: current.revision, bytes: nil, createdAt: nil)
        }
        return (pages + assets).filter { filter.includes($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
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
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LAASpacing.x4) {
                Text(verbatim: current.title).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                Text(verbatim: "\(current.kind) · Revision \(current.revision) · \(LAAWorkPresentation.date(current.syncedAt))")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                if let error {
                    Text(verbatim: error).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    Button { Task { await load() } } label: { Text(verbatim: LAACopy.Studio.retry).frame(minHeight: LAASpacing.minimumTouchTarget) }
                }
                if loading { ProgressView().accessibilityLabel(Text(verbatim: LAACopy.loading)) }
                if draftStorageError {
                    Text(verbatim: "一部の講評下書きを読み書きできません。内容を保持しています。")
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                }
                delivery
                if let detail, let snapshot = activeSnapshot {
                    NavigationLink {
                        LAAStudioReviewView(snapshot: snapshot, project: current, target: .project,
                                            targetName: current.title, revision: current.revision, reviews: detail.reviews)
                    } label: {
                        VStack(alignment: .leading, spacing: LAASpacing.x1) {
                            Text(verbatim: "作品への講評").laaTextStyle(.body).fontWeight(.semibold)
                            if let latest = detail.reviews.first(where: { $0.target == .project }) {
                                Text(verbatim: "現行 · \(LAAStudioReviewView.label(latest.verdict))").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                            }
                        }.frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
                    }
                }
                if let detail {
                    Text(verbatim: "書き出し · \(detail.versions.count)").laaTextStyle(.section).fontWeight(.semibold)
                    Text(verbatim: "新しい版から最大50件を表示します。").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    if versions.isEmpty { Text(verbatim: "取得した範囲に書き出しはありません。").foregroundStyle(LAAColor.secondaryText) }
                    ForEach(Array(versions.enumerated()), id: \.element.id) { index, item in itemLink(item, index: index, items: versions) }
                    if !displacedDrafts.isEmpty, let snapshot = activeSnapshot {
                        Text(verbatim: "一覧にない版の講評下書き").laaTextStyle(.section).fontWeight(.semibold)
                        Text(verbatim: "対象の版は最新50件に含まれていません。内容を確認し、必要ならコピーできます。")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        ForEach(displacedDrafts) { draft in
                            NavigationLink {
                                LAAStudioReviewView(snapshot: snapshot, project: current, target: draft.target,
                                                    targetName: draft.targetName ?? "一覧にない版", revision: draft.revision ?? current.revision,
                                                    reviews: detail.reviews, unavailableInListing: true)
                            } label: {
                                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                                    Text(verbatim: draft.targetName ?? "一覧にない版")
                                    Text(verbatim: draft.state.pending == nil ? "未送信の下書き" : "送信結果を確認")
                                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                }.frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
                            }.accessibilityIdentifier("laa.studio.displaced.\(draft.id)")
                        }
                    }
                }
                Text(verbatim: "ページと素材 · \(items.count)").laaTextStyle(.section).fontWeight(.semibold)
                LAASearchField(placeholder: "名前を検索", text: $search, identifier: "laa.studio.item.search")
                if laaDesktop {
                    LAAMacFlowLayout(spacing: LAASpacing.x2) {
                        filterChips
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: LAASpacing.x2) { filterChips }
                    }.scrollClipDisabled()
                }
                if items.isEmpty { Text(verbatim: "表示できるページや素材はありません。").foregroundStyle(LAAColor.secondaryText) }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in itemLink(item, index: index, items: items) }
            }.padding(LAASpacing.horizontal).laaPageWidth()
        }.background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: LAACopy.Studio.works))
            .tint(LAAColor.link).navigationBarTitleDisplayMode(.inline)
            .task(id: bridge.revision) { await load() }.refreshable { await load() }
            .onAppear { refreshDisplacedDrafts(); if detail != nil { Task { await load() } } }
    }
    @ViewBuilder private var filterChips: some View {
        ForEach(LAAStudioFilter.allCases) { value in
            Button { filter = value } label: {
                Text(verbatim: value.rawValue).studioFilterChip(selected: filter == value)
            }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
        }
    }

    private var delivery: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: LAACopy.Studio.deliverables.uppercased()).laaTextStyle(.section).fontWeight(.semibold)
            if let deliveredRevision {
                Text(verbatim: deliveredRevision == current.revision ? "納品版 Revision \(deliveredRevision)" : "納品版 Revision \(deliveredRevision) · 現在 Revision \(current.revision)")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            } else if detail != nil { Text(verbatim: "納品はまだありません。").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
            if let url = LAAStudioMedia.driveURL(driveURL) {
                Link(destination: url) { Label { Text(verbatim: "Driveで開く") } icon: { Image(systemName: "arrow.up.right.square") }.frame(minHeight: LAASpacing.minimumTouchTarget) }
            }
        }
    }
    private func itemLink(_ item: LAAStudioWorkItem, index: Int, items: [LAAStudioWorkItem]) -> some View {
        NavigationLink {
            LAAStudioItemView(items: items, startIndex: index, project: current, snapshot: activeSnapshot,
                              reviews: detail?.reviews ?? [], driveURL: driveURL, allowsReview: detail != nil)
        } label: {
            HStack(spacing: LAASpacing.x3) {
                LAAStudioThumbnail(path: item.thumbnail, symbol: item.symbol).frame(width: LAASpacing.minimumRowHeight, height: LAASpacing.minimumRowHeight)
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: item.name).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                    Text(verbatim: "\(item.kind.capitalized) · Revision \(item.revision)")
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    if let bytes = item.bytes {
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                    if item.preparing { Text(verbatim: "閲覧用コピーを準備中").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
                }
                Spacer()
            }.padding(LAASpacing.x3).background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
        }.buttonStyle(.plain)
    }
    @MainActor private func load() async {
        guard !loading, LAAStudioData.available(bridge) else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            if snapshot == nil { fetchedSnapshot = try await LAAStudioData.snapshot(bridge) }
            guard activeSnapshot?.supportsV2 == true else { detail = nil; return }
            detail = try await LAAStudioData.project(project.id, bridge: bridge)
            refreshDisplacedDrafts()
        } catch is CancellationError { }
        catch { self.error = LAAStudioData.message(error) }
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

private struct LAAStudioItemView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let items: [LAAStudioWorkItem]
    let project: LAAStudioProject
    let snapshot: LAAStudioSnapshot?
    let driveURL: String?
    let allowsReview: Bool
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
                if allowsReview, let target = item.target, let snapshot {
                    NavigationLink {
                        LAAStudioReviewView(snapshot: snapshot, project: project, target: target,
                                            targetName: item.name, revision: item.revision, reviews: reviews)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: "この\(item.kind == "page" ? "ページ" : "版")への講評")
                            if let latest = reviews.first(where: { $0.target == target }) {
                                Text(verbatim: "現行 · \(LAAStudioReviewView.label(latest.verdict))").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                            }
                        }.frame(minHeight: LAASpacing.minimumTouchTarget)
                    }
                }
            }.padding(LAASpacing.horizontal).laaPageWidth()
        }.background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: "閲覧"))
            .navigationBarTitleDisplayMode(.inline).tint(LAAColor.link)
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
