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
                    if loading { ProgressView().accessibilityLabel(Text(verbatim: "Loading photo")) }
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
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                LAACloseButton { dismiss() }.accessibilityIdentifier("laa.background.close")
            } }
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
        value.bubbleChoice = bubble
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

private struct LAAAssistantInk: ViewModifier {
    let applies: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if applies { content.foregroundStyle(LAAColor.text) } else { content }
    }
}

/// The glass bubbles' values (owner, 2026-11-16 07:00: "背景が少し見える
/// くらいの透明度", the owner's bubble too). Clear glass on both platforms:
/// the Mac draws no tint on regular glass in the light appearance (a grey
/// bubble under the owner's light text, 1.1:1), while clear glass takes it.
/// Tints measured on the brightest picture the dimming allows (a white
/// photo): reply 5.3:1, owner 5.1:1 on iPhone. Colours from
/// `laa-design show app`: the night surface #172627, the owner's teal
/// (`ownBubble`, light #00585E, dark #1E6B70), the paper's glass face
/// #FFFDF8 and rims #D7D5CC / rgba(236,231,220,.16).
enum LAABubbleGlass {
    /// Tint strength of the reply's glass over the dark backgrounds.
    static let replyTintDark = 0.45
    /// Tint strength of the owner's teal glass over the dark backgrounds.
    static let ownTintDark = 0.65
    /// On the paper: the reply's ivory face and the owner's teal.
    static let replyTintLight = 0.55
    static let ownTintLight = 0.92

    @available(iOS 26.0, *)
    static func glass(own: Bool, dark: Bool) -> Glass {
        if dark {
            return .clear.tint(own ? teal(dark: true).opacity(ownTintDark) : night.opacity(replyTintDark))
        }
        return .clear.tint(own ? teal(dark: false).opacity(ownTintLight) : ivory.opacity(replyTintLight))
    }

    static func rim(own: Bool, dark: Bool) -> Color {
        dark || own ? darkRim : lightRim
    }

    static let night = Color(red: 0x17 / 255, green: 0x26 / 255, blue: 0x27 / 255)
    static let ivory = Color(red: 1, green: 253 / 255, blue: 248 / 255)
    static func teal(dark: Bool) -> Color {
        dark ? Color(red: 0x1E / 255, green: 0x6B / 255, blue: 0x70 / 255)
             : Color(red: 0, green: 0x58 / 255, blue: 0x5E / 255)
    }
    static let darkRim = Color(red: 236 / 255, green: 231 / 255, blue: 220 / 255).opacity(0.16)
    static let lightRim = Color(red: 215 / 255, green: 213 / 255, blue: 204 / 255)
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
    /// The shared transcript draws no bubble for an employee or agent
    /// (LAATranscript, 2026-11-24): the reply is set on the paper in ink.
    func laaAssistantSurface() -> some View { modifier(LAAAssistantInk(applies: true)) }
    /// The owner's soft bubble, the transcript's one bubble.
    func laaOwnBubbleSurface() -> some View { laaTranscriptOwnerBubble() }
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
