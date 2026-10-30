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
                                if LAAStaff(profile: snapshot.context.profile) != nil {
                                    Text(verbatim: "GPT-Live")
                                        .laaTextStyle(.secondary)
                                        .foregroundStyle(LAAColor.link)
                                        .accessibilityIdentifier("laa.call.engine")
                                }
                                if let note = snapshot.voiceNote {
                                    Text(verbatim: note)
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
            Text(verbatim: "通話")
                .laaTextStyle(.section)
                .fontWeight(.semibold)
                .foregroundStyle(LAAColor.secondaryText)
            HStack {
                Button(action: calls.showChat) {
                    Label("チャット", systemImage: "chevron.left")
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
        let level = Self.level(snapshot.audioLevel)
        return ZStack {
            Circle()
                .fill(LAAColor.surface)
                .frame(width: 270, height: 270)
            StaffAvatarView(profile: snapshot.context.profile, name: snapshot.context.name, size: 270)
            Circle()
                .strokeBorder(LAAColor.selectionFill, lineWidth: 14)
                .frame(width: 298, height: 298)
                .scaleEffect(reduceMotion ? 1 : 1 + CGFloat(level) * 0.08)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        }
        .frame(width: 300, height: 300)
    }

    static func level(_ value: Float?) -> Float {
        guard let value, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    @ViewBuilder private func status(_ snapshot: LAAEmployeeCallSnapshot) -> some View {
        switch snapshot.phase {
        case .connecting: Text(verbatim: "接続中")
        case .connected:
            if let started = snapshot.connectedAt {
                TimelineView(.periodic(from: started, by: 1)) { timeline in
                    Text(verbatim: "通話中　\(Self.elapsed(since: started, now: timeline.date))")
                        .monospacedDigit()
                }
            } else { Text(verbatim: "通話中") }
        case .ending: Text(verbatim: "終了中")
        case .ended: Text(verbatim: "通話終了")
        case .failed(let message): Text(verbatim: message)
        }
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func controls(_ snapshot: LAAEmployeeCallSnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            CallGlassButton(title: snapshot.muted ? "消音解除" : "消音",
                            symbol: snapshot.muted ? "mic.slash.fill" : "mic.fill",
                            identifier: "laa.call.mute", selected: snapshot.muted,
                            action: calls.toggleMute)
                .disabled(!snapshot.phase.isOngoing)
            if snapshot.usesSystemRoutePicker {
                VStack(spacing: 8) {
                    LAAAudioRoutePicker()
                        .frame(width: 60, height: 60)
                        .modifier(CallGlassCircle(selected: false, destructive: false))
                    Text(verbatim: routeLabel).font(.caption).foregroundStyle(LAAColor.secondaryText)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .disabled(!snapshot.phase.isOngoing)
            } else {
                CallGlassButton(title: routeLabel, symbol: snapshot.speaker ? "speaker.wave.2.fill" : "speaker.fill",
                                identifier: "laa.call.speaker", accessibilityTitle: "スピーカー",
                                selected: snapshot.speaker, action: calls.toggleSpeaker)
                    .disabled(!snapshot.phase.isOngoing)
            }
            CallGlassButton(title: "チャット", symbol: "bubble.left.fill", identifier: "laa.call.chat",
                            action: calls.showChat)
                .disabled(!snapshot.phase.isOngoing)
            CallGlassButton(title: "終了", symbol: "phone.down.fill", identifier: "laa.call.end",
                            destructive: true, action: calls.end)
        }
        .frame(maxWidth: .infinity)
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
        case .builtInReceiver: return "受話口"
        case .builtInSpeaker: return "スピーカー"
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return name.isEmpty ? "Bluetooth" : name
        default:
            return name.isEmpty ? "音声出力" : name
        }
    }

    static func labels(_ outputs: [(type: AVAudioSession.Port, name: String)]) -> String {
        guard !outputs.isEmpty else { return "出力先なし" }
        return outputs.map { label(type: $0.type, name: $0.name) }.joined(separator: "・")
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
        picker.accessibilityLabel = "音声の出力先"
        picker.accessibilityIdentifier = "laa.call.audio-route"
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}

private struct CallGlassCircle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let selected: Bool
    let destructive: Bool

    private var fill: Color {
        destructive ? LAAColor.end : (selected ? LAAColor.selectionFill : LAAColor.surface)
    }

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            styled(content)
                .background(fill, in: Circle())
                .overlay(border)
        } else if #available(iOS 26.0, *) {
            styled(content)
                .glassEffect(.clear.tint(fill).interactive(), in: Circle())
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
    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $calls.isShowingCall) {
            LAAEmployeeCallView(calls: calls)
        }
        .sheet(item: $calls.consentRequest, onDismiss: calls.consentDidDismiss) { request in
            LiveVoiceConsentSheet(mode: request.mode, onAnswer: calls.answerConsent)
                .presentationDetents([.medium, .large])
        }
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
                    Text(verbatim: "通話に戻る")
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
