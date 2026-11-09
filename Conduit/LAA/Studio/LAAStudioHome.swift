#if LAA_BUILD
import SwiftUI
import UIKit
import ImageIO

struct LAAStudioHomeView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var section = 0
    @State private var snapshot: LAAStudioSnapshot?
    @State private var loading = false
    @State private var error: String?
    @State private var pairing = false
    @State private var search = ""
    @Environment(\.laaDesktop) private var laaDesktop
    @State private var desktopSelection: LAAStudioDesktopSelection?
    init(initialSection: Int = 0) { _section = State(initialValue: initialSection) }
    private var columns: [GridItem] {
        if laaDesktop {
            return [GridItem(.adaptive(minimum: LAADesktopMetrics.gridItemMinWidth), spacing: LAASpacing.x6)]
        }
        return dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] :
            [GridItem(.flexible(), spacing: LAASpacing.x2), GridItem(.flexible())]
    }
    var body: some View {
        Group {
            if laaDesktop { desktopContent } else { phoneContent }
        }
        .tint(LAAColor.link)
        .sheet(isPresented: $pairing) { LAAPairingView().environmentObject(bridge).tint(LAAColor.link) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if let snapshot {
                    NavigationLink { LAAStudioCreateView(snapshot: snapshot) } label: { Image(systemName: "plus") }
                        .accessibilityLabel(Text(verbatim: LAACopy.Studio.newRequest)).accessibilityIdentifier("laa.studio.new")
                }
                if LAAStudioData.available(bridge) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading).accessibilityLabel(Text(verbatim: LAACopy.Studio.refresh)).accessibilityIdentifier("laa.studio.refresh")
                }
            }
        }
        .task(id: bridge.revision) { await load() }
    }

    private var phoneContent: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            Picker(selection: $section) {
                Text(verbatim: LAACopy.Studio.works).tag(0)
                Text(verbatim: LAACopy.Studio.requests).tag(1)
                if snapshot?.supportsV2 == true { Text(verbatim: "Library").tag(2) }
            } label: {
                Text(verbatim: "Studio")
            }.pickerStyle(.segmented).frame(minHeight: LAASpacing.minimumTouchTarget)
                .accessibilityIdentifier("laa.studio.section")
            if !LAAStudioData.available(bridge) {
                Text(verbatim: bridge.status == .keychainError ? LAABridgeError.keychain.japaneseText : LAACopy.bridgeNotPairedBody)
                    .laaTextStyle(.body).foregroundStyle(LAAColor.text)
                if bridge.status != .keychainError {
                    Button { pairing = true } label: {
                        Text(verbatim: LAACopy.Brain.connect)
                    }.laaGlassButton(prominent: true)
                        .accessibilityIdentifier("laa.studio.pair")
                }
            } else {
                if let error {
                    Text(verbatim: error).laaTextStyle(.body).foregroundStyle(LAAColor.attention)
                    Button { Task { await load() } } label: {
                        Text(verbatim: LAACopy.Studio.retry)
                    }.laaGlassButton()
                }
                if loading && snapshot == nil { ProgressView().accessibilityLabel(Text(verbatim: LAACopy.loading)) }
                if let snapshot {
                    if !snapshot.online { Text(verbatim: LAACopy.Studio.disconnected).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                    else if !snapshot.accepting { Text(verbatim: LAACopy.Studio.notAccepting).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
                    if !snapshot.supportsV2 {
                        Text(verbatim: "版・講評・原則の詳細は、このStudioでは利用できません。")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                    if section == 0 { works(snapshot) }
                    else if section == 1 { requests(snapshot) }
                    else if snapshot.supportsV2 { LAAStudioCatalogView(snapshot: snapshot) }
                }
            }
        }
    }
    // MARK: Desktop (Mac) list, gallery and detail

    private var desktopContent: some View {
        LAAMacListDetail(listWidth: LAADesktopMetrics.listIdealWidth) {
            desktopList
        } detail: {
            desktopDetail
        }
        .background(LAAColor.background.ignoresSafeArea())
    }

    private var desktopList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                LAAStudioDesktopHeader(canRefresh: LAAStudioData.available(bridge), isRefreshing: loading) {
                    Task { await load() }
                }
                Picker(selection: $section) {
                    Text(verbatim: LAACopy.Studio.works).tag(0)
                    Text(verbatim: LAACopy.Studio.requests).tag(1)
                    if snapshot?.supportsV2 == true { Text(verbatim: "Library").tag(2) }
                } label: {
                    Text(verbatim: LAACopy.tabTitle(.studio))
                }
                .pickerStyle(.segmented)
                .frame(minHeight: LAASpacing.minimumTouchTarget)
                .accessibilityIdentifier("laa.studio.section")
                if !LAAStudioData.available(bridge) {
                    Text(verbatim: bridge.status == .keychainError ? LAABridgeError.keychain.japaneseText : LAACopy.bridgeNotPairedBody)
                        .laaTextStyle(.body).foregroundStyle(LAAColor.text)
                    if bridge.status != .keychainError {
                        Button { pairing = true } label: { Text(verbatim: LAACopy.Brain.connect) }
                            .laaGlassButton(prominent: true)
                            .accessibilityIdentifier("laa.studio.pair")
                    }
                } else {
                    if let error {
                        Text(verbatim: error).laaTextStyle(.body).foregroundStyle(LAAColor.attention)
                        Button { Task { await load() } } label: { Text(verbatim: LAACopy.Studio.retry) }
                    }
                    if loading && snapshot == nil { ProgressView().accessibilityLabel(Text(verbatim: LAACopy.loading)) }
                    if let snapshot {
                        if !snapshot.online {
                            Text(verbatim: LAACopy.Studio.disconnected).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                        }
                        if section == 0 { desktopWorkRows(snapshot) }
                        else if section == 1 { desktopRequestRows(snapshot) }
                        else { Text(verbatim: "Library は右側の広い列に表示します。").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
                    }
                }
            }
            .padding(.horizontal, LAASpacing.x4)
            .padding(.vertical, LAASpacing.x4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func desktopWorkRows(_ snapshot: LAAStudioSnapshot) -> some View {
        let projects = desktopProjects(snapshot)
        TextField(text: $search) { Text(verbatim: "作品を検索") }
            .studioSearchField().accessibilityIdentifier("laa.studio.work.search")
        if projects.isEmpty {
            Text(verbatim: snapshot.projects.isEmpty ? LAACopy.Studio.emptyWorks : "一致する作品はありません。")
                .laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
        } else {
            LAAMacKeyboardList(count: projects.count,
                              selectedIndex: projects.firstIndex { desktopSelection == .work($0.id) },
                              move: { index in
                                  guard projects.indices.contains(index) else { return }
                                  desktopSelection = .work(projects[index].id)
                              },
                              open: {}) {
                VStack(spacing: 0) {
                    ForEach(projects) { project in
                        LAAStudioDesktopRow(title: project.title,
                                            detail: "\(project.kind) · \(LAAWorkPresentation.date(project.syncedAt))",
                                            thumbnail: project.pages.first?.preview,
                                            isSelected: desktopSelection == .work(project.id)) {
                            desktopSelection = .work(project.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func desktopRequestRows(_ snapshot: LAAStudioSnapshot) -> some View {
        if snapshot.requests.isEmpty {
            Text(verbatim: LAACopy.Studio.emptyRequests).laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
        } else {
            desktopRequestGroup(LAACopy.Studio.active, records: snapshot.requests.filter(\.active), snapshot: snapshot)
            desktopRequestGroup(LAACopy.Studio.finished, records: snapshot.requests.filter { !$0.active }, snapshot: snapshot)
        }
    }

    @ViewBuilder private func desktopRequestGroup(_ title: String, records: [LAAStudioRecord], snapshot: LAAStudioSnapshot) -> some View {
        if !records.isEmpty {
            Text(verbatim: title.uppercased()).laaTextStyle(.section).fontWeight(.semibold)
                .foregroundStyle(LAAColor.secondaryText).accessibilityAddTraits(.isHeader)
            ForEach(records) { record in
                LAAStudioDesktopRow(title: snapshot.projects.first { $0.id == record.request.projectId }?.title
                                        ?? record.request.create?.title ?? record.request.prompt,
                                    detail: LAAWorkPresentation.date(record.updatedAt),
                                    status: record.status == "approval" ? LAACopy.Studio.needsApproval : LAAStudioPresentation.status(record.status),
                                    attention: record.status == "approval",
                                    symbol: "bubble.left.and.text.bubble.right",
                                    isSelected: desktopSelection == .request(record.id)) {
                    desktopSelection = .request(record.id)
                }
                .accessibilityIdentifier("laa.studio.request.\(record.id)")
            }
        }
    }

    @ViewBuilder private var desktopDetail: some View {
        if section == 2, let snapshot, snapshot.supportsV2 {
            LAAStudioCatalogView(snapshot: snapshot)
        } else if let selection = desktopSelection, case .work(let id) = selection,
                  let project = snapshot?.projects.first(where: { $0.id == id }) {
            LAAStudioWorkBody(project: project, snapshot: snapshot)
        } else if let selection = desktopSelection, case .request(let id) = selection,
                  let record = snapshot?.requests.first(where: { $0.id == id }) {
            LAAStudioRequestView(initial: record,
                                 initialProject: snapshot?.projects.first { $0.id == record.request.projectId })
                .laaReadableWidth(LAADesktopMetrics.documentWidth)
        } else {
            LAAMacEmptyDetail(symbol: "square.stack.3d.up", title: "作品を選ぶ",
                              message: "左の一覧から作品を選ぶと、ここに詳細とプレビューを表示します。")
        }
    }

    private func desktopProjects(_ snapshot: LAAStudioSnapshot) -> [LAAStudioProject] {
        snapshot.projects.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    private func works(_ snapshot: LAAStudioSnapshot) -> some View {
        let projects = snapshot.projects.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        return VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Text(verbatim: "\(LAACopy.Studio.works.uppercased()) · \(projects.count)").laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
            TextField(text: $search) { Text(verbatim: "作品を検索") }.studioSearchField().accessibilityIdentifier("laa.studio.work.search")
            if projects.isEmpty { Text(verbatim: snapshot.projects.isEmpty ? LAACopy.Studio.emptyWorks : "一致する作品はありません。").foregroundStyle(LAAColor.secondaryText) }
            else {
                LazyVGrid(columns: columns, spacing: LAASpacing.x2) {
                    ForEach(projects) { project in
                        NavigationLink { LAAStudioWorkView(project: project, snapshot: snapshot) } label: {
                            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                                LAAStudioThumbnail(path: project.pages.first?.preview, symbol: "doc.richtext")
                                    .aspectRatio(1, contentMode: .fit)
                                Text(verbatim: project.title).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                                Text(verbatim: "\(project.kind) · \(LAAWorkPresentation.date(project.syncedAt))")
                                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                            }.padding(LAASpacing.x3).frame(maxWidth: .infinity, alignment: .leading)
                                .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                        }.buttonStyle(.plain).accessibilityIdentifier("laa.studio.work.\(project.id)")
                    }
                }
            }
        }
    }
    private func requests(_ snapshot: LAAStudioSnapshot) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            if snapshot.requests.isEmpty { Text(verbatim: LAACopy.Studio.emptyRequests).foregroundStyle(LAAColor.secondaryText) }
            requestGroup(LAACopy.Studio.active, records: snapshot.requests.filter(\.active), snapshot: snapshot)
            requestGroup(LAACopy.Studio.finished, records: snapshot.requests.filter { !$0.active }, snapshot: snapshot)
        }
    }
    private func requestGroup(_ title: String, records: [LAAStudioRecord], snapshot: LAAStudioSnapshot) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            if !records.isEmpty {
                Text(verbatim: title.uppercased()).laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                ForEach(records) { record in
                    NavigationLink {
                        LAAStudioRequestView(initial: record, initialProject: snapshot.projects.first { $0.id == record.request.projectId })
                    } label: {
                        VStack(alignment: .leading, spacing: LAASpacing.x1) {
                            Text(verbatim: snapshot.projects.first(where: { $0.id == record.request.projectId })?.title ?? record.request.create?.title ?? record.request.prompt)
                                .laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text).lineLimit(2)
                            HStack(spacing: LAASpacing.x1) {
                                if record.status == "approval" {
                                    Label(LAACopy.Studio.needsApproval, systemImage: "exclamationmark.circle.fill")
                                        .foregroundStyle(LAAColor.attention)
                                } else {
                                    Text(verbatim: LAAStudioPresentation.status(record.status)).foregroundStyle(LAAColor.secondaryText)
                                }
                                Text(verbatim: "· \(LAAWorkPresentation.date(record.updatedAt))").foregroundStyle(LAAColor.secondaryText)
                            }.laaTextStyle(.secondary)
                        }.padding(LAASpacing.x4).frame(maxWidth: .infinity, alignment: .leading)
                            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                    }.buttonStyle(.plain).accessibilityIdentifier("laa.studio.request.\(record.id)")
                }
            }
        }
    }
    @MainActor private func load() async {
        guard LAAStudioData.available(bridge) else { snapshot = nil; return }
        loading = true; error = nil
        do {
            snapshot = try await LAAStudioData.snapshot(bridge)
            if snapshot?.supportsV2 != true && section == 2 { section = 0 }
        }
        catch is CancellationError { }
        catch { self.error = LAAStudioData.message(error) }
        loading = false
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
    @MainActor private func load() async {
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
