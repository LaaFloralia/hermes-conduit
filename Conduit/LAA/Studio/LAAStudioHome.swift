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
    init(initialSection: Int = 0) { _section = State(initialValue: initialSection) }
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] :
            [GridItem(.flexible(), spacing: LAASpacing.x2), GridItem(.flexible())]
    }
    var body: some View {
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
