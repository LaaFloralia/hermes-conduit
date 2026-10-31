#if LAA_BUILD
import SwiftUI

struct LAAStudioWorkView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let project: LAAStudioProject
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x6) {
                Text(verbatim: project.title).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                Text(verbatim: "\(project.kind) · \(LAAWorkPresentation.date(project.syncedAt))").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                if LAAStudioMedia.driveURL(project.driveUrl) != nil || project.deliveredRevision != nil {
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        Text(verbatim: LAACopy.Studio.deliverables.uppercased()).laaTextStyle(.section).fontWeight(.semibold)
                        if let url = LAAStudioMedia.driveURL(project.driveUrl) {
                            Link(destination: url) {
                                Label(LAACopy.Studio.open, systemImage: "arrow.up.right.square")
                                    .frame(minHeight: LAASpacing.minimumTouchTarget)
                            }
                        }
                        if let revision = project.deliveredRevision { Text(verbatim: "Revision \(revision)").laaTextStyle(.secondary) }
                    }
                }
                if !project.pages.isEmpty {
                    Text(verbatim: LAACopy.Studio.pages.uppercased()).laaTextStyle(.section).fontWeight(.semibold)
                    ForEach(project.pages) { page in
                        NavigationLink { LAAStudioImageView(name: page.name, path: page.preview) } label: {
                            assetRow(name: page.name, subtitle: "Page", image: page.preview, symbol: "doc")
                        }.buttonStyle(.plain).disabled(LAAStudioMedia.bridgePath(page.preview) == nil)
                        if LAAStudioMedia.bridgePath(page.preview) == nil {
                            Text(verbatim: LAACopy.Studio.pageUnsupported).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                    }
                }
                if let assets = project.assets, !assets.isEmpty {
                    Text(verbatim: LAACopy.Studio.assets.uppercased()).laaTextStyle(.section).fontWeight(.semibold)
                    ForEach(assets) { asset in
                        if let path = LAAStudioMedia.bridgePath(asset.url), ["image", "video", "audio"].contains(asset.kind), asset.unavailable == nil {
                            NavigationLink {
                                if asset.kind == "image" { LAAStudioImageView(name: asset.name, path: asset.url) }
                                else { LAAStudioPlayerView(asset: asset, path: path) }
                            } label: { assetRow(name: asset.name, subtitle: asset.kind.capitalized, image: asset.poster ?? (asset.kind == "image" ? asset.url : nil), symbol: asset.kind == "image" ? "photo" : "play.rectangle") }
                                .buttonStyle(.plain)
                        } else {
                            assetRow(name: asset.name, subtitle: asset.kind.capitalized, image: asset.poster, symbol: "doc")
                            Text(verbatim: asset.unavailable ?? LAACopy.Studio.unsupported).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                    }
                }
            }.padding(LAASpacing.horizontal).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: LAACopy.Studio.works))
        .tint(LAAColor.link)
        .navigationBarTitleDisplayMode(.inline)
    }
    private func assetRow(name: String, subtitle: String, image: String?, symbol: String) -> some View {
        HStack(spacing: LAASpacing.x3) {
            LAAStudioThumbnail(path: image, symbol: symbol).frame(width: LAASpacing.minimumRowHeight, height: LAASpacing.minimumRowHeight)
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                Text(verbatim: name).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                Text(verbatim: subtitle).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            Spacer()
        }.padding(LAASpacing.x3).background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
    }
}

struct LAAStudioImageView: View {
    let name: String
    let path: String?
    var body: some View {
        ScrollView {
            LAAStudioThumbnail(path: path, symbol: "photo")
                .aspectRatio(1, contentMode: .fit).padding(LAASpacing.horizontal)
        }.background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: name))
            .navigationBarTitleDisplayMode(.inline).tint(LAAColor.link)
    }
}

struct LAAStudioPlayerView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let asset: LAAStudioAsset
    let path: String
    private var item: LAADriveItem? {
        let mime = asset.kind == "video" ? "video/mp4" : "audio/mpeg"
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": "studioasset", "name": asset.name, "mimeType": mime, "kind": "file", "downloadable": true]) else { return nil }
        return try? JSONDecoder().decode(LAADriveItem.self, from: data)
    }
    var body: some View {
        Group {
            if let item {
                LAADrivePlayerView(item: item, bridge: bridge, studioPath: path, autoPlay: true)
                    .id("\(bridge.revision):\(path)")
            }
            else { Text(verbatim: LAACopy.Studio.unsupported) }
        }.background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: asset.name))
            .navigationBarTitleDisplayMode(.inline).tint(LAAColor.link)
    }
}
#endif
