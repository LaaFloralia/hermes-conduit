#if LAA_BUILD
import SwiftUI
import UIKit

/// Pages through images already loaded in the current list. Each page makes a
/// fresh metadata/permission check and pins the subsequent preview to its version.
struct LAADriveImagePager: View {
    let items: [LAADriveItem]
    @State private var selected: String

    init(items: [LAADriveItem], initialID: String) {
        self.items = items
        _selected = State(initialValue: initialID)
    }

    var body: some View {
        VStack(spacing: LAASpacing.x1) {
            Text("Swipe through images already loaded in this list.")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            TabView(selection: $selected) {
                ForEach(items) { item in
                    LAADriveImagePage(item: item).tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
        }
    }
}

private struct LAADriveImagePage: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let item: LAADriveItem
    @State private var image: UIImage?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        VStack(spacing: LAASpacing.x2) {
            Text(verbatim: item.name).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            if let image { LAADriveZoomImage(image: image) }
            else if let error {
                Text(verbatim: error).foregroundStyle(LAAColor.attention)
                Button("Retry") { retry += 1 }
            } else { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(bridge.revision):\(retry)") {
            image = nil; error = nil
            do {
                let metadata = try await LAADriveData.metadata(item, bridge: bridge)
                guard let reason = LAADrivePresentation.reason(metadata) else {
                    let bytes = try await LAADriveContent.preview(metadata, bridge: bridge)
                    try Task.checkCancellation()
                    guard let decoded = UIImage(data: bytes) else { error = LAACopy.Drive.invalidPreview; return }
                    image = decoded
                    return
                }
                error = reason
            } catch is CancellationError { }
            catch { self.error = LAADrivePresentation.message(error) }
        }
        .onDisappear { image = nil }
    }
}
#endif
