#if LAA_BUILD
import SwiftUI

struct LAAWorkImagePayload: Codable { let data: String; let mimeType: String }

/// A picture of the conversation, read from the Bridge, as a thumbnail of one
/// fixed height: the same frame before and after it loads, so the transcript
/// does not jump (owner, 2026-11-12: a screenshot grew to about 950 pt). The
/// picture keeps its proportions; a very wide one is cropped at the sides. A
/// tap opens the whole picture over the screen.
struct LAAWorkSessionImage: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let sessionID: String
    let imageID: String
    @State private var image: UIImage?
    @State private var failed = false
    @State private var preview: LAAWorkImagePreview.Request?
    var body: some View {
        Group {
            if let image {
                Button { preview = .init(images: [image], index: 0) } label: {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: Self.width(image), height: Self.height)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "添付画像"))
                .accessibilityHint(Text(verbatim: "全画面で開く"))
                .accessibilityIdentifier("work.session.image")
            }
            else if failed { Text(verbatim: "画像を取得できません。") }
            else {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LAAColor.subtleSurface)
                    .frame(width: Self.placeholderWidth, height: Self.height)
                    .accessibilityLabel(String("添付画像を読み込み中"))
            }
        }.task(id: imageID) {
            do {
                let payload: LAAWorkImagePayload = try await bridge.read("/v1/sessions/\(sessionID)/images/\(imageID)")
                if let data = Data(base64Encoded: payload.data) { image = UIImage(data: data) }
                failed = image == nil
            } catch { failed = true }
        }
        .laaImagePreview($preview)
    }

    /// Under the owner's 280 pt cap for a tall picture, whatever it is.
    static let height: CGFloat = 240
    static let maxWidth: CGFloat = 300
    static let placeholderWidth: CGFloat = 180

    static func width(_ image: UIImage) -> CGFloat {
        guard image.size.height > 0 else { return placeholderWidth }
        return min(maxWidth, max(80, height * image.size.width / image.size.height))
    }
}
#endif
