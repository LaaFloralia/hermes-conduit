#if LAA_BUILD
import SwiftUI

struct LAAStudioWorkView: View {
    let project: LAAStudioProject
    var snapshot: LAAStudioSnapshot? = nil
    var body: some View { LAAStudioWorkBody(project: project, snapshot: snapshot) }
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
            if let item { LAADrivePlayerView(item: item, bridge: bridge, studioPath: path) }
            else { Text(verbatim: LAACopy.Studio.unsupported) }
        }.background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: asset.name))
            .navigationBarTitleDisplayMode(.inline).tint(LAAColor.link)
    }
}
#endif
