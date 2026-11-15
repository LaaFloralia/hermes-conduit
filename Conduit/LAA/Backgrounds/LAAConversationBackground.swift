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
                .environment(\.laaBubble, value.bubble)
                .background(LAAColor.background.ignoresSafeArea())
        } else {
            content
                .environment(\.laaBackgroundKind, value.kind)
                .environment(\.laaBubble, value.bubble)
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
    @State private var sheet: LAAConversationFeatures.Sheet?
    var body: some View {
        Group {
            Button {
                if let key = LAAConversationScope.current(appState) { sheet = .background(key) }
            } label: { Label(LAACopy.chatBackground, systemImage: "photo.on.rectangle") }
                .disabled(LAAConversationScope.current(appState) == nil)
                .accessibilityIdentifier("conversation.background")
            if appState.activeRoomSurface != nil {
                Button { sheet = .group } label: { Label(LAACopy.chatGroupSettings, systemImage: "person.2") }
            }
        }.sheet(item: $sheet) { selection in
            switch selection {
            case .background(let key): LAABackgroundPicker(key: key)
            case .group: LAAGroupSettingsView().environmentObject(appState)
            }
        }
    }
}

/// The background entry in the chat's bar, beside the call button. The bar
/// held it in the conversation menu until the 2026-11-11 header left only the
/// mascot's introduction to reach it; it is back on the bar, presenting
/// through the screen's `LAAConversationFeatures` as it did (owner, 2026-11-15).
@MainActor
struct LAAConversationBackgroundButton: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var features: LAAConversationFeatures

    var body: some View {
        let key = LAAConversationScope.current(appState)
        Button {
            if let key { features.sheet = .background(key) }
        } label: {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 20))
                .foregroundStyle(LAAColor.link)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .laaComposerGlass(in: Circle())
        .disabled(key == nil)
        .accessibilityLabel(Text(verbatim: LAACopy.chatBackground))
        .accessibilityIdentifier("laa.employee.background")
    }
}

private struct LAABackgroundKindKey: EnvironmentKey {
    static let defaultValue = LAABackground.Kind.paper
}
private struct LAABubbleKey: EnvironmentKey {
    static let defaultValue = LAABackground.Bubble.standard
}
extension EnvironmentValues {
    var laaBackgroundKind: LAABackground.Kind {
        get { self[LAABackgroundKindKey.self] }
        set { self[LAABackgroundKindKey.self] = newValue }
    }
    /// The conversation's bubble choice, beside its background.
    var laaBubble: LAABackground.Bubble {
        get { self[LAABubbleKey.self] }
        set { self[LAABubbleKey.self] = newValue }
    }
}

@MainActor
private struct LAAConversationFeaturesModifier: ViewModifier {
    @StateObject private var features = LAAConversationFeatures()
    @ObservedObject private var store = LAABackgroundStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let _ = store.revision
        let value = LAAConversationScope.current(appState).map { store.setting(for: $0) } ?? LAABackground()
        let kind = value.kind
        content
            .environment(\.laaBackgroundKind, kind)
            .environment(\.laaBubble, value.bubble)
            .environment(\.colorScheme, kind == .paper ? colorScheme : .dark)
            .environmentObject(features)
            .sheet(item: $features.sheet) { sheet in
                switch sheet {
                case .background(let key): LAABackgroundPicker(key: key)
                case .group: LAAGroupSettingsView().environmentObject(appState)
                }
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
                // Bubbles belong to an employee's chat; a group room's
                // bubbles keep their own look.
                if key.surface == .chat {
                    Section {
                        ForEach(LAABackground.Bubble.allCases, id: \.self) { bubble in
                            Button { select(bubble) } label: {
                                HStack {
                                    Text(label(bubble))
                                    Spacer()
                                    if value.bubble == bubble { Image(systemName: "checkmark") }
                                }
                            }
                            .accessibilityIdentifier("bubble.choice.\(bubble.rawValue)")
                            .accessibilityValue(Text(verbatim: value.bubble == bubble ? LAACopy.chatSelected : ""))
                        }
                    } header: {
                        Text("吹き出し")
                    } footer: {
                        if reduceTransparency && value.bubble == .glass {
                            Text("「透明度を下げる」がオンの間は、不透明の吹き出しで表示します。")
                        }
                    }
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

    private func select(_ bubble: LAABackground.Bubble) {
        value.bubble = bubble
        persist()
    }

    private func label(_ bubble: LAABackground.Bubble) -> LocalizedStringKey {
        switch bubble {
        case .standard: return "いまの見た目"
        case .glass: return "Liquid Glass"
        }
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

/// A message bubble: the opaque surface (the owner's teal, the reply's
/// paper card), or Liquid Glass when the conversation's bubble choice is
/// `glass`. The glass is regular, tinted with the design's glass face (or
/// the owner's teal) so the text keeps its contrast over a photo, and has
/// the glass's 1pt rim. Reduce Transparency and iOS 17–25 keep the opaque
/// surface.
private struct LAABubbleSurface: ViewModifier {
    let own: Bool
    @Environment(\.laaBubble) private var bubble
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: LAARadius.bubble, style: .continuous)
        let padded = content.padding(.horizontal, 14).padding(.vertical, 10)
            .modifier(LAAAssistantInk(applies: !own))
        if #available(iOS 26.0, *), bubble == .glass, !reduceTransparency {
            #if targetEnvironment(macCatalyst)
            // The Mac's glass drew no tint (a grey bubble under the owner's
            // light text, 1.5:1), so the colour lies on the glass instead.
            padded
                .background(own ? LAABubbleGlass.macOwnFace : LAABubbleGlass.face, in: shape)
                .glassEffect(.regular, in: shape)
                .overlay { shape.strokeBorder(own ? LAABubbleGlass.ownRim : LAABubbleGlass.rim, lineWidth: 1) }
            #else
            padded
                .glassEffect(.regular.tint(own ? LAABubbleGlass.ownTint : LAABubbleGlass.face), in: shape)
                .overlay { shape.strokeBorder(own ? LAABubbleGlass.ownRim : LAABubbleGlass.rim, lineWidth: 1) }
            #endif
        } else {
            padded.background(own ? LAAColor.ownBubble : LAAColor.surface, in: shape)
        }
    }
}

private struct LAAAssistantInk: ViewModifier {
    let applies: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if applies { content.foregroundStyle(LAAColor.text) } else { content }
    }
}

/// The glass bubbles' colours, from the design's glass values for the
/// operating layer (`laa-design show app`: face rgba(255,253,248,.72) and
/// rim #D7D5CC; dark face rgba(36,54,56,.66) and rim rgba(236,231,220,.16)).
enum LAABubbleGlass {
    static let face = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 36 / 255, green: 54 / 255, blue: 56 / 255, alpha: 0.66)
            : UIColor(red: 1, green: 253 / 255, blue: 248 / 255, alpha: 0.72)
    })
    static let rim = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 236 / 255, green: 231 / 255, blue: 220 / 255, alpha: 0.16)
            : UIColor(red: 215 / 255, green: 213 / 255, blue: 204 / 255, alpha: 1)
    })
    /// The owner's teal (`ownBubble`) as the glass's tint.
    static let ownTint = LAAColor.ownBubble
    /// On the Mac the teal lies on the glass, dense enough to keep the
    /// owner's light text at 4.5:1 over the palest glass.
    static let macOwnFace = LAAColor.ownBubble.opacity(0.85)
    static let ownRim = Color(uiColor: UIColor(red: 236 / 255, green: 231 / 255, blue: 220 / 255, alpha: 0.16))
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
    func laaAssistantSurface() -> some View { modifier(LAABubbleSurface(own: false)) }
    func laaOwnBubbleSurface() -> some View { modifier(LAABubbleSurface(own: true)) }
    func laaPhotoSupportingText() -> some View { modifier(LAAPhotoSupportingText()) }
    func laaGroupSurface() -> some View { modifier(LAAGroupSurface()) }
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
