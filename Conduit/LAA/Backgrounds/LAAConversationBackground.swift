import SwiftUI

private struct LAAClearGlassControlsKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var laaClearGlassControls: Bool {
        get { self[LAAClearGlassControlsKey.self] }
        set { self[LAAClearGlassControlsKey.self] = newValue }
    }
}

#if LAA_BUILD
import PhotosUI
import UIKit

@MainActor
enum LAAConversationScope {
    static func current(_ state: AppState) -> LAABackgroundKey? {
        if let room = state.activeRoomSurface {
            return LAABackgroundKey(dashboard: room.dashboardID, profile: state.activeProfile,
                                    conversation: room.room.roomID, surface: .group)
        }
        if state.showsOfflineChatCopy, let offline = state.offlineChatPresentation {
            guard let session = offline.composerSessionID else { return nil }
            return LAABackgroundKey(dashboard: offline.dashboardID, profile: offline.profile,
                                    conversation: session, surface: .chat)
        }
        guard !state.showsPendingNewChat, let dashboard = state.activeDashboardID else { return nil }
        let identity = ChatView.activeScrollSessionKey(in: state)
        guard let identity, identity.isValid else { return nil }
        return LAABackgroundKey(dashboard: dashboard, profile: identity.profile,
                                conversation: identity.sessionID, surface: .chat)
    }
}

@MainActor
private struct LAAConversationBackgroundModifier: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = LAABackgroundStore.shared

    func body(content: Content) -> some View {
        let key = LAAConversationScope.current(appState)
        let value = key.map { store.setting(for: $0) } ?? LAABackground()
        let _ = store.revision
        if value.kind == .paper {
            content.environment(\.laaBackgroundKind, .paper)
                .background(LAAColor.background.ignoresSafeArea())
        } else {
            content
                .environment(\.laaBackgroundKind, value.kind)
                .environment(\.colorScheme, .dark)
                .background { LAABackgroundCanvas(value: value, image: key.flatMap { store.image(for: $0) }) }
        }
    }
}

struct LAABackgroundCanvas: View {
    let value: LAABackground
    let image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LAAColors.paper
                switch value.kind {
                case .paper:
                    Color.clear
                case .tealNight:
                    Color(red: 0.02, green: 0.18, blue: 0.19)
                case .ink:
                    Color(red: 0.055, green: 0.075, blue: 0.08)
                case .photo:
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .blur(radius: value.blur, opaque: true)
                            .clipped()
                        Color.black.opacity(value.safeDim)
                        // Clear controls over a photo have a dimmed backing.
                        LinearGradient(stops: [
                            .init(color: .black.opacity(0.35), location: 0),
                            .init(color: .clear, location: 0.22),
                            .init(color: .clear, location: 0.78),
                            .init(color: .black.opacity(0.35), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
final class LAAConversationFeatures: ObservableObject {
    enum Sheet: Identifiable {
        case background(LAABackgroundKey), group
        var id: String {
            switch self { case .background(let key): return "background-" + key.fileID; case .group: return "group" }
        }
    }
    @Published var sheet: Sheet?
}

@MainActor
struct LAAConversationMenuItems: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var features: LAAConversationFeatures

    var body: some View {
        Button {
            if let key = LAAConversationScope.current(appState) { features.sheet = .background(key) }
        } label: {
            Label(LAACopy.chatBackground, systemImage: "photo.on.rectangle")
        }
        .disabled(LAAConversationScope.current(appState) == nil)
        .accessibilityIdentifier("conversation.background")
        if appState.activeRoomSurface != nil {
            Button { features.sheet = .group } label: {
                Label(LAACopy.chatGroupSettings, systemImage: "person.2")
            }
            Button {} label: {
                Label(LAACopy.chatGroupCallUnavailable, systemImage: "phone")
            }
            .disabled(true)
            .accessibilityIdentifier("room.call.reason")
        }
    }
}

private struct LAABackgroundKindKey: EnvironmentKey {
    static let defaultValue = LAABackground.Kind.paper
}
extension EnvironmentValues {
    var laaBackgroundKind: LAABackground.Kind {
        get { self[LAABackgroundKindKey.self] }
        set { self[LAABackgroundKindKey.self] = newValue }
    }
}

@MainActor
private struct LAAConversationFeaturesModifier: ViewModifier {
    @StateObject private var features = LAAConversationFeatures()
    @ObservedObject private var store = LAABackgroundStore.shared
    @EnvironmentObject private var appState: AppState

    func body(content: Content) -> some View {
        let _ = store.revision
        let kind = LAAConversationScope.current(appState).map { store.setting(for: $0).kind } ?? .paper
        let configured = content
            .environment(\.laaBackgroundKind, kind)
            .environmentObject(features)
            .sheet(item: $features.sheet) { sheet in
                switch sheet {
                case .background(let key): LAABackgroundPicker(key: key)
                case .group: LAAGroupSettingsView().environmentObject(appState)
                }
            }
        if kind == .paper {
            configured
        } else {
            configured
                .environment(\.colorScheme, .dark)
        }
    }
}

@MainActor
struct LAABackgroundPicker: View {
    let key: LAABackgroundKey
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LAABackgroundStore.shared
    @State private var value = LAABackground()
    @State private var photo: PhotosPickerItem?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        let photoSelected = value.kind == .photo
        NavigationStack {
            Form {
                Section(LAACopy.chatBackground) {
                    ForEach(LAABackground.Kind.allCases.filter { $0 != .photo }, id: \.self) { kind in
                        Button { select(kind) } label: {
                            HStack {
                                Text(label(kind))
                                Spacer()
                                if value.kind == kind { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityIdentifier("background.choice.\(kind.rawValue)")
                        .accessibilityValue(Text(verbatim: value.kind == kind ? LAACopy.chatSelected : ""))
                    }
                    PhotosPicker(selection: $photo, matching: .images) {
                        HStack {
                            Text(verbatim: LAACopy.chatDevicePhoto)
                            Spacer()
                            if photoSelected { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityIdentifier("background.choice.photo")
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_BACKGROUND") {
                        Button(LAACopy.chatFixturePhoto) { importFixture() }
                            .accessibilityIdentifier("background.fixture.photo")
                    }
                    #endif
                    if loading { ProgressView(LAACopy.chatLoadingPhoto) }
                }
                if value.kind == .photo {
                    Section {
                        Slider(value: Binding(get: { value.dim }, set: { value.dim = $0; persist() }), in: 0...0.6)
                            .accessibilityLabel(Text(verbatim: LAACopy.chatPhotoDim))
                            .accessibilityIdentifier("background.photo.dim")
                        Text(verbatim: "\(LAACopy.chatPhotoDim) \(Int((value.dim * 100).rounded()))%")
                        Slider(value: Binding(get: { value.blur }, set: { value.blur = $0; persist() }), in: 0...20)
                            .accessibilityLabel(Text(verbatim: LAACopy.chatPhotoBlur))
                            .accessibilityIdentifier("background.photo.blur")
                        Text(verbatim: "\(LAACopy.chatPhotoBlur) \(Int(value.blur.rounded())) pt")
                        if value.safeDim > value.dim + 0.005 {
                            Text(verbatim: "読みやすさのため減光を自動で追加します。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text(verbatim: LAACopy.chatPhotoAdjustments) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(Text(verbatim: LAACopy.chatBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(LAACopy.chatDone) { dismiss() } } }
            .onAppear { value = store.setting(for: key) }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                loading = true
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw LAABackgroundError.invalidPhoto }
                        try store.savePhoto(data, for: key, dim: value.dim, blur: value.blur)
                        value = store.setting(for: key)
                        error = nil
                    } catch { self.error = "写真を保存できませんでした。別の写真をお試しください。" }
                    loading = false
                }
            }
        }
    }

    private func select(_ kind: LAABackground.Kind) {
        value.kind = kind
        persist()
    }

    private func persist() {
        do { try store.save(value, for: key); error = nil }
        catch { self.error = "背景を保存できませんでした。" }
    }

    private func label(_ kind: LAABackground.Kind) -> String {
        switch kind {
        case .paper: return LAACopy.chatPaper
        case .tealNight: return LAACopy.chatTealNight
        case .ink: return LAACopy.chatInk
        case .photo: return LAACopy.chatDevicePhoto
        }
    }

    #if DEBUG
    private func importFixture() {
        guard let data = LAABackgroundFixturePhoto.data() else { return }
        do { try store.savePhoto(data, for: key, dim: 0, blur: 0); value = store.setting(for: key); error = nil }
        catch { self.error = "テスト写真を保存できませんでした。" }
    }
    #endif
}

private struct LAAAssistantSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(LAASpacing.x4)
            .foregroundStyle(LAAColor.text)
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.bubble, style: .continuous))
    }
}
private struct LAAPhotoSupportingText: ViewModifier {
    @Environment(\.laaBackgroundKind) private var kind
    @ViewBuilder func body(content: Content) -> some View {
        if kind == .photo {
            content.foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.82), in: Capsule())
        } else { content }
    }
}
private struct LAAGroupSurface: ViewModifier {
    @Environment(\.laaBackgroundKind) private var kind
    @ViewBuilder func body(content: Content) -> some View {
        if kind == .paper { content }
        else { content.background(LAAColors.surface, in: RoundedRectangle(cornerRadius: 19, style: .continuous)) }
    }
}
private struct LAAComposerSurface: ViewModifier {
    @Environment(\.laaBackgroundKind) private var kind
    let foundation: Color
    @ViewBuilder func body(content: Content) -> some View {
        if kind == .photo {
            if #available(iOS 26.0, *) {
                content.background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .glassEffect(.clear, in: .rect(cornerRadius: 30))
            } else {
                content.background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            }
        } else {
            content.background(foundation, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
    }
}
private struct LAAPhotoGlassScope: ViewModifier {
    @Environment(\.laaBackgroundKind) private var kind
    func body(content: Content) -> some View { content.environment(\.laaClearGlassControls, kind == .photo) }
}
private struct LAAGroupTitleGlass: ViewModifier {
    @Environment(\.laaBackgroundKind) private var kind
    @ViewBuilder func body(content: Content) -> some View {
        if kind == .photo {
            content
                .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .conduitGlassSurface(cornerRadius: 20, tint: .conduitAccent.opacity(0.06), clear: true)
        } else {
            content.conduitGlassSurface(cornerRadius: 20, tint: .conduitAccent.opacity(0.06))
        }
    }
}
private struct LAAToolbarGlass: ViewModifier {
    @Environment(\.laaBackgroundKind) private var kind
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), kind == .photo {
            content.background(.black.opacity(0.38), in: Circle()).glassEffect(.clear, in: .circle)
        } else { content }
    }
}
extension View {
    func laaConversationBackground() -> some View { modifier(LAAConversationBackgroundModifier()) }
    func laaConversationFeatures() -> some View { modifier(LAAConversationFeaturesModifier()) }
    func laaAssistantSurface() -> some View { modifier(LAAAssistantSurface()) }
    func laaPhotoSupportingText() -> some View { modifier(LAAPhotoSupportingText()) }
    func laaGroupSurface() -> some View { modifier(LAAGroupSurface()) }
    func laaComposerSurface(_ foundation: Color) -> some View { modifier(LAAComposerSurface(foundation: foundation)) }
    func laaComposerGlassScope() -> some View { modifier(LAAPhotoGlassScope()) }
    func laaPhotoGlassScope() -> some View { modifier(LAAPhotoGlassScope()) }
    func laaGroupTitleGlass() -> some View { modifier(LAAGroupTitleGlass()) }
    func laaToolbarGlass() -> some View { modifier(LAAToolbarGlass()) }
}
#else
extension View {
    func laaConversationBackground() -> some View { self }
    func laaConversationFeatures() -> some View { self }
    func laaAssistantSurface() -> some View { self }
    func laaPhotoSupportingText() -> some View { self }
    func laaGroupSurface() -> some View { self }
    func laaComposerSurface(_ foundation: Color) -> some View {
        background(foundation, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
    func laaComposerGlassScope() -> some View { self }
    func laaPhotoGlassScope() -> some View { self }
    func laaGroupTitleGlass() -> some View {
        conduitGlassSurface(cornerRadius: 20, tint: .conduitAccent.opacity(0.06))
    }
    func laaToolbarGlass() -> some View { self }
}
#endif
