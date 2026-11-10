#if LAA_BUILD
import PhotosUI
import SwiftUI

extension LAACopy {
    static let ownerIcon = "アイコン"
    static let ownerIconChoose = "写真を選ぶ"
    static let ownerIconRemove = "写真を外す"
    static let ownerIconSaveFailed = "アイコンを保存できません"
    static let ownerIconRemoveFailed = "アイコンを外せません"
    static let ownerIconUnreadable = "写真を読み込めません"
}

/// The owner's picture: choose a photo (cropped square, 256 px) or remove
/// it. The Mac stores it, so every device shows the same face.
struct LAAOwnerAvatarSettingsCard: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject private var store = LAAOwnerAvatarStore.shared
    @State private var photo: PhotosPickerItem?
    @State private var notice: String?

    private var paired: Bool { bridge.status == .paired }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            HStack(spacing: LAASpacing.x3) {
                LAAOwnerAvatarView(size: 56)
                    .accessibilityIdentifier("laa.settings.ownerIcon.preview")
                LAAOwnerHeader()
                Spacer(minLength: 0)

            }
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .laaTextStyle(.secondary)
                    .foregroundStyle(LAAColor.attention)
                    .accessibilityIdentifier("laa.settings.ownerIcon.notice")
            }
            HStack(spacing: LAASpacing.x4) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Text(verbatim: "写真を変更")
                        .frame(minHeight: LAASpacing.minimumTouchTarget).contentShape(Rectangle())
                }
                .accessibilityIdentifier("laa.settings.ownerIcon.choose")
                if store.image != nil {
                    Button { remove() } label: {
                        Text(verbatim: LAACopy.ownerIconRemove)
                            .frame(minHeight: LAASpacing.minimumTouchTarget).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("laa.settings.ownerIcon.remove")
                }
            }
            .disabled(!paired || store.busy)
            .laaTextStyle(.body)
            .foregroundStyle(paired ? LAAColor.link : LAAColor.secondaryText)
        }
        .padding(LAASpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await save(item) }
        }
        .task(id: bridge.revision) { await store.refresh(bridge: bridge) }
    }

    @MainActor private func save(_ item: PhotosPickerItem) async {
        notice = nil
        guard let data = try? await item.loadTransferable(type: Data.self), let picture = UIImage(data: data) else {
            notice = LAACopy.ownerIconUnreadable
            return
        }
        do {
            try await store.save(picture, bridge: bridge)
        } catch LAAOwnerAvatarStore.SaveError.unreadableImage {
            notice = LAACopy.ownerIconUnreadable
        } catch is CancellationError {
        } catch {
            notice = LAACopy.ownerIconSaveFailed
        }
    }

    private func remove() {
        notice = nil
        Task { @MainActor in
            do { try await store.remove(bridge: bridge) } catch is CancellationError {} catch {
                notice = LAACopy.ownerIconRemoveFailed
            }
        }
    }
}
#endif
