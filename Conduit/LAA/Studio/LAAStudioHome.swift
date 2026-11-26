#if LAA_BUILD
import LAAKit
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
    @State private var submitted: LAAStudioRecord?
    @State private var library = false
    @State private var showingRules = false
    @State private var searching = false
    @State private var search = ""
    @State private var scope = ""
    @State private var reviewed: [String: Int] = [:]
    @State private var reviewChecks: [String: Date] = [:]
    init(initialSection: Int = 0) {
        _library = State(initialValue: initialSection == 2)
    }
    var body: some View {
        Group {
            if desktop {
                ScrollView {
                    VStack(alignment: .leading, spacing: LAASpacing.section) {
                        LAADocTitle(title: LAACopy.tabTitle(.studio))
                        contents
                    }
                    .laaDocPaper()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LAAColor.background.ignoresSafeArea())
            } else {
                contents
            }
        }
        .tint(LAAColor.link)
        .onReceive(NotificationCenter.default.publisher(for: .laaStudioChanged)) { notice in
            if let record = notice.object as? LAAStudioRecord { submitted = record }
            Task { await load(refreshReviews: true) }
        }
        .sheet(isPresented: $pairing) { LAAPairingView().environmentObject(bridge) }
        .navigationDestination(isPresented: $showingRules) { LAADriveOperatingRulesView(surface: .studio) }
        .sheet(isPresented: $library) {
            NavigationStack {
                if let snapshot { ScrollView { LAAStudioCatalogView(snapshot: snapshot).padding(LAASpacing.horizontal) }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { library = false } } }
                }
            }.environmentObject(bridge)
        }
        .refreshable { await load(refreshReviews: true) }
        .task(id: bridge.revision) {
            let next = LAAStudioCache.scope(bridge)
            if next != scope {
                snapshot = nil; submitted = nil; scope = next; reviewChecks = [:]
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

    private var contents: some View {
        VStack(alignment: .leading, spacing: LAASpacing.section) {
            if !LAAStudioData.available(bridge) {
                Text(verbatim: "Macに接続してください").foregroundStyle(LAAColor.secondaryText)
                Button("Connect") { pairing = true }.laaGlassButton()
                    .accessibilityIdentifier("laa.studio.pair")
            } else {
                if let error {
                    LAAStudioConnectionLine(message: error) { Task { await load() } }
                } else if let snapshot, !snapshot.online {
                    LAAStudioConnectionLine(message: "Studioに接続できません") { Task { await load() } }
                }
                LAAStudioCreateView(snapshot: snapshot ?? .init(online: false, accepting: false, lastSeen: nil,
                    projects: [], principles: [], requests: []), inline: true)
                    .id(scope)
                if let snapshot {
                    LAAStudioProgressSection(snapshot: snapshot, submitted: submitted)
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        HStack {
                            LAASectionHeader("Works")
                            Spacer()
                            Menu {
                                Button("Search", systemImage: "magnifyingglass") { searching.toggle() }
                                if snapshot.supportsV2 {
                                    Button("Library", systemImage: "books.vertical") { library = true }
                                        .accessibilityIdentifier("laa.studio.library.open")
                                }
                                Button("Rules", systemImage: "doc.text") { showingRules = true }
                                    .accessibilityIdentifier("laa.studio.rules")
                            } label: {
                                let target = (desktop ? LAACanvas.mac : .iphone).touchTarget
                                Image(systemName: "ellipsis").frame(width: target, height: target)
                            }
                            .accessibilityLabel("Works Menu").accessibilityIdentifier("laa.studio.menu")
                        }
                        if searching {
                            LAASearchField(placeholder: "Search", text: $search, identifier: "laa.studio.work.search")
                        }
                        LAAStudioWorksList(
                            projects: snapshot.projects.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) },
                            awaitingReview: Set(LAAStudioPresentation.awaitingReview(snapshot).filter { reviewed[$0.id] != $0.revision }.map(\.id)),
                            snapshot: snapshot, desktop: desktop)
                    }
                } else if loading {
                    LAALoadingDots()
                }
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
            if let submitted, result.requests.contains(where: { $0.id == submitted.id }) { self.submitted = nil }
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
            Button(String("再試行"), action: retry).frame(minHeight: 44)
        }
    }
}

private struct LAAStudioProgressSection: View {
    let snapshot: LAAStudioSnapshot
    let submitted: LAAStudioRecord?
    private var records: [LAAStudioRecord] {
        let pending = snapshot.requests.filter(\.active)
        guard let submitted, submitted.active, !pending.contains(where: { $0.id == submitted.id }) else { return pending }
        return [submitted] + pending
    }
    var body: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                LAASectionHeader("In Progress")
                VStack(spacing: 0) {
                    ForEach(records) { record in
                        NavigationLink {
                            LAAStudioRequestView(initial: record, initialProject: snapshot.projects.first { $0.id == record.request.projectId })
                        } label: {
                            LAAStudioProgressRow(record: record, title: LAAStudioPresentation.title(for: record, project: snapshot.projects.first { $0.id == record.request.projectId }))
                        }.buttonStyle(.plain).accessibilityIdentifier("laa.studio.request.\(record.id)")
                    }
                }
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
            Text(verbatim: LAAStudioPresentation.status(record.status))
                .laaTextStyle(.secondary)
                .foregroundStyle(record.status == "approval" ? LAAColor.attention : LAAColor.secondaryText)
        }.padding(.vertical, LAASpacing.x2).frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(LAAColor.separator).frame(height: LAAStroke.rule) }
            .contentShape(Rectangle())
    }
}

private struct LAAStudioWorksList: View {
    let projects: [LAAStudioProject]
    let awaitingReview: Set<String>
    let snapshot: LAAStudioSnapshot
    let desktop: Bool

    var body: some View {
        let groups = Dictionary(grouping: projects) { LAAStudioWorkKind(project: $0) }
        if projects.isEmpty {
            Text(verbatim: "作品はまだありません").laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
        } else {
            LazyVStack(alignment: .leading, spacing: LAASpacing.x4) {
                ForEach(LAAStudioWorkKind.allCases.filter { groups[$0] != nil }, id: \.self) { kind in
                    Section {
                        VStack(spacing: 0) {
                            ForEach(groups[kind] ?? []) { project in
                                NavigationLink { LAAStudioWorkView(project: project, snapshot: snapshot) } label: {
                                    HStack(spacing: LAASpacing.x2) {
                                        Text(verbatim: project.title).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                        Spacer(minLength: LAASpacing.x2)
                                        if awaitingReview.contains(project.id) {
                                            Text("Review").laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                                        } else {
                                            Text(verbatim: LAAStudioPresentation.relativeDate(project.syncedAt))
                                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                        }
                                    }
                                    .frame(minHeight: (desktop ? LAACanvas.mac : .iphone).rowMinHeight)
                                    .overlay(alignment: .bottom) { Rectangle().fill(LAAColor.separator).frame(height: LAAStroke.rule) }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).accessibilityIdentifier("laa.studio.work.\(project.id)")
                            }
                        }
                    } header: {
                        Text(verbatim: kind.rawValue).laaOperating(.label).foregroundStyle(LAAColor.secondaryText)
                            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("laa.studio.kind.\(kind.rawValue)")
                    }
                }
            }
        }
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
        #if DEBUG
        if LAAStudioData.fixture != nil, let path, let cover = LAAStudioData.fixtureCover(path: path) {
            image = cover
            return
        }
        #endif
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
