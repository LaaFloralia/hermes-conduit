#if LAA_BUILD
import SwiftUI
import UIKit
import ImageIO

struct LAAStudioHomeView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.laaDesktop) private var desktop
    @State private var snapshot: LAAStudioSnapshot?
    @State private var loading = false
    @State private var error: String?
    @State private var pairing = false
    @State private var creating = false
    @State private var submitted = false
    @State private var library = false
    @State private var searching = false
    @State private var search = ""
    @State private var scope = ""
    @State private var reviewed: [String: Int] = [:]
    @State private var reviewChecks: [String: Date] = [:]
    var requestGeneration: Int = 0
    init(initialSection: Int = 0, requestGeneration: Int = 0) {
        self.requestGeneration = requestGeneration
        _library = State(initialValue: initialSection == 2)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.section) {
            if !LAAStudioData.available(bridge) {
                Text("Macに接続してください").foregroundStyle(LAAColor.secondaryText)
                Button("接続する") { pairing = true }.laaGlassButton()
                    .accessibilityIdentifier("laa.studio.pair")
            } else {
                if let error {
                    LAAStudioConnectionLine(message: error) { Task { await load() } }
                } else if let snapshot, !snapshot.online {
                    LAAStudioConnectionLine(message: "Studioに接続できません") { Task { await load() } }
                } else if let snapshot, !snapshot.accepting {
                    LAAStudioConnectionLine(message: "Studioに接続できません") { Task { await load() } }
                }
                Button { submitted = false; creating = true } label: {
                    HStack {
                        Text("何を作りますか").font(.body)
                        Spacer()
                        Image(systemName: "plus")
                    }.foregroundStyle(LAAColor.link).padding(LAASpacing.x4)
                        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight)
                        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                }.buttonStyle(.plain).accessibilityIdentifier("laa.studio.create")
                if submitted { Text("依頼しました").foregroundStyle(LAAColor.secondaryText) }
                if let snapshot {
                    LAAStudioProgressSection(snapshot: snapshot)
                    LAAStudioReviewQueue(snapshot: snapshot, reviewed: reviewed)
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        HStack {
                            Text("作品").font(.footnote.weight(.semibold)).foregroundStyle(LAAColor.secondaryText)
                            Spacer()
                            Menu {
                                Button("検索", systemImage: "magnifyingglass") { searching.toggle() }
                                if snapshot.supportsV2 { Button("ライブラリ", systemImage: "books.vertical") { library = true } }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel("作品のメニュー").accessibilityIdentifier("laa.studio.menu")
                        }
                        if searching {
                            LAASearchField(placeholder: "検索", text: $search, identifier: "laa.studio.work.search")
                        }
                        LAAStudioWorksGrid(projects: snapshot.projects.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }, snapshot: snapshot, desktop: desktop)
                    }
                } else if loading {
                    LAAStudioSkeleton()
                }
            }
        }
        .tint(LAAColor.link)
        .onChange(of: requestGeneration, initial: true) { _, generation in
            if generation > 0 { creating = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .laaStudioChanged)) { notice in
            if notice.object is LAAStudioRecord { submitted = true }
            Task { await load(refreshReviews: true) }
        }
        .sheet(isPresented: $pairing) { LAAPairingView().environmentObject(bridge) }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) {
            NavigationStack { LAAStudioCreateView(snapshot: snapshot ?? LAAStudioSnapshot(online: false, accepting: false, lastSeen: nil, projects: [], principles: [], requests: [])) }
                .environmentObject(bridge)
        }
        .sheet(isPresented: $library) {
            NavigationStack {
                if let snapshot { ScrollView { LAAStudioCatalogView(snapshot: snapshot).padding(LAASpacing.horizontal) }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { library = false } } }
                }
            }.environmentObject(bridge)
        }
        .refreshable { await load(refreshReviews: true) }
        .task(id: bridge.revision) {
            let next = LAAStudioCache.scope(bridge)
            if next != scope {
                snapshot = nil; scope = next; reviewChecks = [:]
                reviewed = LAAStudioCache.load([String: Int].self, scope: next, item: "reviewed") ?? [:]
            }
            if snapshot == nil { snapshot = LAAStudioCache.loadSnapshot(scope: scope) }
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(8)) } catch { break }
                await load()
            }
        }
    }
    @MainActor private func load(refreshReviews: Bool = false) async {
        guard !loading, LAAStudioData.available(bridge) else { return }
        loading = true; defer { loading = false }
        let revision = bridge.revision
        do {
            let result = try await LAAStudioData.snapshot(bridge)
            guard revision == bridge.revision, !Task.isCancelled else { return }
            snapshot = result; error = nil
            LAAStudioCache.saveSnapshot(result, scope: LAAStudioCache.scope(bridge))
            if result.supportsV2 {
                for project in LAAStudioPresentation.awaitingReview(result) {
                    let key = project.id + "-" + String(project.revision)
                    if !refreshReviews, let checked = reviewChecks[key], Date().timeIntervalSince(checked) < 60 { continue }
                    guard revision == bridge.revision, !Task.isCancelled else { return }
                    if let detail = try? await LAAStudioData.project(project.id, bridge: bridge) {
                        guard revision == bridge.revision else { return }
                        reviewChecks[key] = Date()
                        if detail.reviews.contains(where: { $0.target == .project && $0.revision == project.revision && $0.verdict != nil }) {
                            reviewed[project.id] = project.revision
                        } else { reviewed.removeValue(forKey: project.id) }
                    }
                }
                LAAStudioCache.save(reviewed, scope: scope, item: "reviewed")
            }
        } catch is CancellationError { }
        catch {
            guard revision == bridge.revision else { return }
            if LAAStudioData.isAuthorizationFailure(error) { snapshot = nil }
            self.error = LAAStudioData.isAuthorizationFailure(error) ? LAAStudioData.message(error) : "Studioに接続できません"
        }
    }
}

struct LAAStudioConnectionLine: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack(spacing: LAASpacing.x2) {
            Text(verbatim: message).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            Spacer(minLength: 0)
            Button("再試行", action: retry).frame(minHeight: 44)
        }
    }
}

private struct LAAStudioProgressSection: View {
    let snapshot: LAAStudioSnapshot
    private var records: [LAAStudioRecord] { snapshot.requests.filter(\.active) }
    var body: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                Text("進行中").font(.footnote.weight(.semibold)).foregroundStyle(LAAColor.secondaryText)
                VStack(spacing: 0) {
                    ForEach(records) { record in
                        NavigationLink {
                            LAAStudioRequestView(initial: record, initialProject: snapshot.projects.first { $0.id == record.request.projectId })
                        } label: {
                            LAAStudioProgressRow(record: record, title: LAAStudioPresentation.title(for: record, project: snapshot.projects.first { $0.id == record.request.projectId }))
                        }.buttonStyle(.plain).accessibilityIdentifier("laa.studio.request.\(record.id)")
                        if record.id != records.last?.id { Divider().padding(.horizontal, LAASpacing.x4) }
                    }
                }.background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            }
        }
    }
}

private struct LAAStudioProgressRow: View {
    let record: LAAStudioRecord
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: title).font(.body.weight(.semibold)).foregroundStyle(LAAColor.text).lineLimit(2)
            HStack {
                Text(verbatim: LAAStudioPresentation.status(record.status))
                    .foregroundStyle(record.status == "approval" ? LAAColor.attention : LAAColor.link)
                    .padding(.horizontal, LAASpacing.x1).padding(.vertical, 2)
                    .background(LAAColor.selectionFill, in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                Text(verbatim: LAAStudioPresentation.relativeDate(record.updatedAt)).foregroundStyle(LAAColor.secondaryText)
            }.laaTextStyle(.secondary)
            if record.status == "running" {
                // No percentage is provided by intake; a steady line identifies active production.
                Capsule().fill(LAAColor.link).frame(height: 2).accessibilityHidden(true)
            }
        }.padding(LAASpacing.x4).frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
    }
}

private struct LAAStudioReviewQueue: View {
    let snapshot: LAAStudioSnapshot
    let reviewed: [String: Int]
    private var projects: [LAAStudioProject] { LAAStudioPresentation.awaitingReview(snapshot).filter { reviewed[$0.id] != $0.revision } }
    var body: some View {
        if !projects.isEmpty {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                Text("確認待ち").font(.footnote.weight(.semibold)).foregroundStyle(LAAColor.secondaryText)
                ForEach(projects) { project in
                    NavigationLink { LAAStudioWorkView(project: project, snapshot: snapshot) } label: {
                        VStack(alignment: .leading, spacing: LAASpacing.x3) {
                            LAAStudioThumbnail(path: project.pages.first?.preview ?? project.assets?.first?.poster, symbol: LAAStudioPresentation.symbol(project))
                                .frame(height: 190)
                            HStack { Text(verbatim: project.title).foregroundStyle(LAAColor.text); Spacer(); Text("見る").foregroundStyle(LAAColor.link) }
                        }.padding(LAASpacing.x3).background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                    }.buttonStyle(.plain).accessibilityIdentifier("laa.studio.review-work.\(project.id)")
                }
            }
        }
    }
}

private struct LAAStudioWorksGrid: View {
    let projects: [LAAStudioProject]
    let snapshot: LAAStudioSnapshot
    let desktop: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    private var columns: [GridItem] {
        desktop ? [GridItem(.adaptive(minimum: LAADesktopMetrics.gridItemMinWidth), spacing: LAASpacing.x4)] :
            Array(repeating: GridItem(.flexible(), spacing: LAASpacing.x2), count: typeSize.isAccessibilitySize ? 1 : 2)
    }
    var body: some View {
        if projects.isEmpty {
            Text("作品はまだありません").foregroundStyle(LAAColor.secondaryText).frame(maxWidth: .infinity, minHeight: 100)
        } else {
            LazyVGrid(columns: columns, spacing: LAASpacing.x4) {
                ForEach(projects) { project in
                    NavigationLink { LAAStudioWorkView(project: project, snapshot: snapshot) } label: {
                        VStack(alignment: .leading, spacing: LAASpacing.x2) {
                            LAAStudioThumbnail(path: project.pages.first?.preview ?? project.assets?.first?.poster, symbol: LAAStudioPresentation.symbol(project))
                                .aspectRatio(1, contentMode: .fit)
                            Text(verbatim: project.title).font(.body).foregroundStyle(LAAColor.text).lineLimit(2)
                            Text(verbatim: LAAStudioPresentation.relativeDate(project.syncedAt)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityIdentifier("laa.studio.work.\(project.id)")
                }
            }
        }
    }
}

struct LAAStudioSkeleton: View {
    var body: some View {
        VStack(spacing: LAASpacing.x2) {
            ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: LAARadius.card).fill(LAAColor.subtleSurface).frame(height: LAASpacing.minimumRowHeight) }
        }.accessibilityLabel("作品を読み込み中")
    }
}

struct LAAStudioThumbnail: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let path: String?
    let symbol: String
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: LAARadius.card).fill(LAAColor.subtleSurface)
            if let image { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: LAARadius.card)) }
            else { Image(systemName: symbol).foregroundStyle(LAAColor.link) }
        }.task(id: path) { await load() }
    }
    @MainActor private func load(refreshReviews: Bool = false) async {
        image = nil
        guard let path = LAAStudioMedia.bridgePath(path, allowed: ["jpg", "png", "webp"]),
              let suffix = path.split(separator: ".").last,
              let mime = ["jpg": "image/jpeg", "png": "image/png", "webp": "image/webp"][String(suffix)] else { return }
        do {
            var data = Data(); var total: Int64?
            repeat {
                let part = try await bridge.driveRange(path: path, offset: Int64(data.count), length: LAADriveContent.chunkSize)
                try Task.checkCancellation()
                guard part.total > 0, part.total <= 16 * 1024 * 1024, total == nil || total == part.total,
                      part.mimeType?.lowercased() == mime,
                      !part.data.isEmpty, Int64(part.data.count) <= part.total - Int64(data.count) else { return }
                total = part.total; data.append(part.data)
            } while Int64(data.count) < (total ?? 0)
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return }
            try Task.checkCancellation()
            image = UIImage(cgImage: thumb)
        } catch { image = nil }
    }
}
#endif
