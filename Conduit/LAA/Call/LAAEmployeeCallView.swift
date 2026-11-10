#if LAA_BUILD
import SwiftUI
import AVFAudio
import AVKit
import Combine

struct LAAEmployeeCallView: View {
    @ObservedObject var calls: LAAEmployeeCallCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var routeLabel = LAAAudioRouteLabel.current()

    var body: some View {
        ZStack {
            LAAColor.background
                .ignoresSafeArea()
            if let snapshot = calls.snapshot {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            header(snapshot)
                            avatar(snapshot)
                                .padding(.top, LAASpacing.x8 + LAASpacing.x6)
                            VStack(spacing: LAASpacing.x2) {
                                Text(snapshot.context.name)
                                    .font(LAAType.screenTitle)
                                    .accessibilityIdentifier("laa.call.name")
                                status(snapshot)
                                    .font(.subheadline)
                                    .foregroundStyle(LAAColor.secondaryText)
                                    .accessibilityIdentifier("laa.call.status")
                                if snapshot.voiceNote != nil {
                                    Text(verbatim: "音声の設定を反映できませんでした")
                                        .laaTextStyle(.secondary)
                                        .foregroundStyle(LAAColor.secondaryText)
                                        .multilineTextAlignment(.center)
                                        .accessibilityIdentifier("laa.call.voice-note")
                                }
                            }
                            .padding(.top, LAASpacing.x2)
                            Spacer(minLength: LAASpacing.x8)
                            controls(snapshot)
                                .padding(.bottom, LAASpacing.x8 + LAASpacing.x4)
                        }
                        .frame(maxWidth: 540)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        .padding(.horizontal, LAASpacing.horizontal)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .foregroundStyle(LAAColor.text)
        .accessibilityIdentifier("laa.call.screen")
        .interactiveDismissDisabled()
        .onAppear { routeLabel = LAAAudioRouteLabel.current() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)) { _ in
                routeLabel = LAAAudioRouteLabel.current()
            }
    }

    private func header(_ snapshot: LAAEmployeeCallSnapshot) -> some View {
        ZStack {
            HStack {
                Button(action: calls.showChat) {
                    Label {
                        Text(verbatim: "チャット")
                    } icon: {
                        Image(systemName: "chevron.left")
                    }
                }
                .foregroundStyle(LAAColor.link)
                .disabled(!snapshot.phase.isOngoing)
                .accessibilityIdentifier("laa.call.back")
                Spacer()
            }
        }
        .frame(height: 44)
    }

    private func avatar(_ snapshot: LAAEmployeeCallSnapshot) -> some View {
        StaffMascotView(profile: snapshot.context.profile, name: snapshot.context.name, size: 330,
                        activity: snapshot.speaking ? .lively : .resting, level: Self.level(snapshot.audioLevel))
            .frame(width: 340, height: 340)
    }

    static func level(_ value: Float?) -> Float {
        guard let value, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    @ViewBuilder private func status(_ snapshot: LAAEmployeeCallSnapshot) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: Self.statusText(snapshot))
            if case .failed(let message) = snapshot.phase {
                Text(verbatim: message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
        }
    }

    static func statusText(_ snapshot: LAAEmployeeCallSnapshot) -> String {
        switch snapshot.phase {
        case .connecting: return "接続中…"
        case .reconnecting: return "再接続中…"
        case .connected:
            switch snapshot.activity {
            case .ready: return "話せます"
            case .listening: return "聞いています"
            case .thinking: return "考えています"
            }
        case .ending: return "終了中…"
        case .ended, .failed: return "切れました"
        }
    }

    // DESIGN-V3 §9 keeps these four visible labels stable when toggled.
    static let controlTitles = ["消音", "スピーカー", "チャット", "終了"]

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func controls(_ snapshot: LAAEmployeeCallSnapshot) -> some View {
        // One compositing pass for the row of glass controls.
        ConduitGlassGroup(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                CallGlassButton(title: Self.controlTitles[0],
                                symbol: snapshot.muted ? "mic.slash.fill" : "mic.fill",
                                identifier: "laa.call.mute", accessibilityTitle: snapshot.muted ? "消音を解除" : "消音", selected: snapshot.muted,
                                action: calls.toggleMute)
                    .disabled(!snapshot.phase.isOngoing)
                if snapshot.usesSystemRoutePicker {
                    VStack(spacing: 8) {
                        LAAAudioRoutePicker()
                            .frame(width: 60, height: 60)
                            .modifier(CallGlassCircle(selected: false, destructive: false))
                        Text(verbatim: Self.controlTitles[1]).font(.caption).foregroundStyle(LAAColor.secondaryText)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(!snapshot.phase.isOngoing)
                } else {
                    CallGlassButton(title: Self.controlTitles[1],
                                    symbol: snapshot.speaker ? "speaker.wave.2.fill" : "speaker.fill",
                                    identifier: "laa.call.speaker", accessibilityTitle: "スピーカー、\(routeLabel)",
                                    selected: snapshot.speaker, action: calls.toggleSpeaker)
                        .disabled(!snapshot.phase.isOngoing)
                }
                CallGlassButton(title: Self.controlTitles[2], symbol: "bubble.left.fill",
                                identifier: "laa.call.chat", action: calls.showChat)
                    .disabled(!snapshot.phase.isOngoing)
                CallGlassButton(title: Self.controlTitles[3], symbol: "phone.down.fill", identifier: "laa.call.end",
                                destructive: true, action: calls.end)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct CallGlassButton: View {
    let title: String
    let symbol: String
    let identifier: String
    var accessibilityTitle: String? = nil
    var selected = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .frame(width: 60, height: 60)
                    .modifier(CallGlassCircle(selected: selected, destructive: destructive))
                Text(title).font(.caption).foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(accessibilityTitle ?? title)
    }
}

enum LAAAudioRouteLabel {
    static func label(type: AVAudioSession.Port, name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .builtInReceiver: return LAACopy.callReceiver
        case .builtInSpeaker: return LAACopy.callSpeaker
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return name.isEmpty ? "Bluetooth" : name
        default:
            return name.isEmpty ? LAACopy.callAudioRoute : name
        }
    }

    static func labels(_ outputs: [(type: AVAudioSession.Port, name: String)]) -> String {
        guard !outputs.isEmpty else { return LAACopy.callNoOutput }
        return outputs.map { label(type: $0.type, name: $0.name) }.joined(separator: ", ")
    }

    static func current() -> String {
        labels(AVAudioSession.sharedInstance().currentRoute.outputs.map { ($0.portType, $0.portName) })
    }
}

private struct LAAAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor(LAAColor.link)
        picker.activeTintColor = UIColor(LAAColor.link)
        picker.prioritizesVideoDevices = false
        picker.accessibilityLabel = "スピーカー、音声の出力先"
        picker.accessibilityIdentifier = "laa.call.audio-route"
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}

private struct CallGlassCircle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let selected: Bool
    let destructive: Bool

    /// `regular`, not `clear`: the call screen sits on the app's paper, where
    /// clear would leave the symbols floating on a flat colour. Only the
    /// selected control and the end button carry a tint.
    private var tint: Color? {
        destructive ? LAAColor.end : (selected ? LAAColor.selectionFill : nil)
    }

    private var fill: Color {
        destructive ? LAAColor.end : (selected ? LAAColor.selectionFill : LAAColor.surface)
    }

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            styled(content)
                .glassEffect(.regular.tint(tint).interactive(), in: Circle())
                .overlay(border)
        } else {
            styled(content)
                .background(fill, in: Circle())
                .overlay(border)
        }
    }

    private func styled(_ content: Content) -> some View {
        content.foregroundStyle(destructive ? LAAColor.filledButtonText : LAAColor.link)
    }

    private var border: some View {
        Circle().strokeBorder(destructive ? Color.clear : LAAColor.separator, lineWidth: 1)
            .allowsHitTesting(false)
    }
}

struct LAACallPresentation: ViewModifier {
    @ObservedObject var calls: LAAEmployeeCallCoordinator
    var topBanner: AnyView? = nil
    var bottomOverlay: AnyView? = nil
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        // On the Mac the call is a page the window holds, not a cover over
        // the whole window. Its own host keeps it from competing with the
        // consent sheet for the window's single sheet slot.
        content
            .sheet(isPresented: $calls.isShowingCall) {
                callSurface.laaSheetSize(.page)
            }
            .background {
                Color.clear
                    .sheet(item: $calls.consentRequest, onDismiss: calls.consentDidDismiss) { request in
                        LiveVoiceConsentSheet(mode: request.mode, onAnswer: calls.answerConsent)
                            .laaSheetSize(.picker)
                    }
            }
        #else
        content.fullScreenCover(isPresented: $calls.isShowingCall) {
            callSurface
        }
        .sheet(item: $calls.consentRequest, onDismiss: calls.consentDidDismiss) { request in
            LiveVoiceConsentSheet(mode: request.mode, onAnswer: calls.answerConsent)
                .presentationDetents([.medium, .large])
        }
        #endif
    }

    private var callSurface: some View {
        LAAEmployeeCallView(calls: calls)
            .safeAreaInset(edge: .top, spacing: 0) { topBanner }
            .overlay(alignment: .bottom) { bottomOverlay }
    }
}

struct LAAInCallBar: View {
    @ObservedObject var calls: LAAEmployeeCallCoordinator
    let profile: String
    let conversationID: String?

    var body: some View {
        if let snapshot = calls.snapshot,
           !calls.isShowingCall,
           snapshot.context.profile == profile,
           snapshot.context.conversationID == conversationID {
            Button(action: calls.showCall) {
                HStack(spacing: 8) {
                    Image(systemName: "phone.fill")
                    if case .failed = snapshot.phase {
                        Text(verbatim: "通話を確認してください")
                    } else {
                        Text(verbatim: "\(snapshot.context.name) と通話中")
                    }
                    Spacer()
                    Text(verbatim: LAACopy.callReturn)
                    Image(systemName: "chevron.right")
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .foregroundStyle(LAAColors.ink)
                .background(LAAColors.surface)
            }
            .accessibilityIdentifier("laa.call.return")
        }
    }
}

struct LAAInCallBarModifier: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var calls: LAAEmployeeCallCoordinator
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            LAAInCallBar(calls: calls, profile: appState.conversationIdentityProfile,
                         conversationID: appState.activeSessionId)
        }
    }
}
#endif
