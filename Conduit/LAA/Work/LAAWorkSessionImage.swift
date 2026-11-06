#if LAA_BUILD
import SwiftUI

struct LAAWorkImagePayload: Codable { let data: String; let mimeType: String }
struct LAAWorkSessionImage: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let sessionID: String
    let imageID: String
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(Text(verbatim: "添付画像")).accessibilityIdentifier("work.session.image") }
            else if failed { Text(verbatim: "画像を取得できません。") }
            else { ProgressView() }
        }.task(id: imageID) {
            do {
                let payload: LAAWorkImagePayload = try await bridge.read("/v1/sessions/\(sessionID)/images/\(imageID)")
                if let data = Data(base64Encoded: payload.data) { image = UIImage(data: data) }
                failed = image == nil
            } catch { failed = true }
        }
    }
}
#endif
