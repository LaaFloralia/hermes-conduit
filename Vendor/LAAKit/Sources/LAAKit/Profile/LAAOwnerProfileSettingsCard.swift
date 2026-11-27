import SwiftUI
#if canImport(PhotosUI) && !os(watchOS)
import PhotosUI
#endif

/// The owner's name and picture, the same in every LAA app (Hortensia's owner-icon settings, moved into the kit
/// for D-30). Editing here updates `LAAOwnerProfileStore` (shared App Group), so the tab bar's right capsule and
/// the sidebar entry of every app show it. `onAvatarChange` lets a host mirror the prepared JPEG elsewhere
/// (Hortensia → Bridge `/v1/owner/avatar`); nil means removed.
public struct LAAOwnerProfileSettingsCard: View {
    let explicitStore: LAAOwnerProfileStore?
    let onAvatarChange: (@Sendable (Data?) async throws -> Void)?

    @State private var draft: String?
    @State private var notice: String?
    @State private var busy = false
    #if canImport(PhotosUI) && !os(watchOS)
    @State private var photo: PhotosPickerItem?
    #endif
    @FocusState private var nameFocused: Bool
    @Environment(\.laaPalette) private var palette

    public init(store: LAAOwnerProfileStore? = nil,
                onAvatarChange: (@Sendable (Data?) async throws -> Void)? = nil) {
        self.explicitStore = store
        self.onAvatarChange = onAvatarChange
    }

    private var store: LAAOwnerProfileStore { explicitStore ?? .shared }
    private var name: Binding<String> {
        Binding(get: { draft ?? store.displayName }, set: { draft = $0 })
    }
    private var pending: Bool {
        guard let draft else { return false }
        return LAAOwnerProfileStore.resolvedName(draft) != store.displayName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LAASpace.s12) {
            HStack(spacing: LAASpace.s12) {
                LAAProfileImage(profile: store.avatarImage, initial: store.initial, size: 56)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("laa.profile.preview")
                VStack(alignment: .leading, spacing: LAASpace.s4) {
                    TextField("Name", text: name)
                        .laaFont(LAAPlatform.current.canvas.heading, weight: .semibold)
                        .foregroundStyle(palette.text)
                        .textFieldStyle(.plain)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit(commitName)
                        .accessibilityLabel(Text("Name"))
                        .accessibilityIdentifier("laa.profile.name")
                    Text(store.isSharedContainer ? "Shown in every LAA app" : "Shown in this app")
                        .laaFont(LAAPlatform.current.canvas.small)
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            if let notice {
                Text(notice)
                    .laaFont(LAAPlatform.current.canvas.small)
                    .foregroundStyle(palette.critical)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("laa.profile.notice")
            }

            actionRow {
                #if canImport(PhotosUI) && !os(watchOS)
                PhotosPicker(selection: $photo, matching: .images) { Text("Change Photo") }
                    .buttonStyle(.laaText)
                    .accessibilityIdentifier("laa.profile.choose")
                #endif
                if store.avatarData != nil {
                    Button("Remove Photo", action: removeAvatar)
                        .buttonStyle(.laaText)
                        .accessibilityIdentifier("laa.profile.remove")
                }
                if pending {
                    Button("Save", action: commitName)
                        .buttonStyle(.laaText)
                        .accessibilityIdentifier("laa.profile.save")
                } else if store.isCustomName {
                    Button("Reset to \(LAAOwnerProfileStore.defaultDisplayName)") {
                        draft = nil
                        store.saveDisplayName("")
                    }
                    .buttonStyle(.laaText)
                    .accessibilityIdentifier("laa.profile.reset")
                }
            }
            .disabled(busy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
        #if canImport(PhotosUI) && !os(watchOS)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await save(item) }
        }
        #endif
    }

    /// The actions wrap as whole words (Watch: one per line).
    @ViewBuilder private func actionRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(watchOS)
        VStack(alignment: .leading, spacing: LAASpace.s4) { content() }
        #else
        LAAWrapRow(spacing: LAASpace.s16, lineSpacing: LAASpace.s4) { content() }
        #endif
    }

    private func commitName() {
        guard let draft else { return }
        store.saveDisplayName(draft)
        self.draft = nil
    }

    #if canImport(PhotosUI) && !os(watchOS)
    private func save(_ item: PhotosPickerItem) async {
        notice = nil
        busy = true
        defer { busy = false }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            notice = LAAOwnerProfileError.unreadableImage.errorDescription
            return
        }
        do {
            try store.saveAvatar(imageData: data)
            try await onAvatarChange?(store.avatarData)
        } catch is CancellationError {
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "The picture could not be saved."
        }
    }
    #endif

    private func removeAvatar() {
        notice = nil
        store.removeAvatar()
        guard let onAvatarChange else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await onAvatarChange(nil) } catch is CancellationError {} catch {
                notice = "The picture was removed here but not everywhere. \(error.localizedDescription)"
            }
        }
    }
}
