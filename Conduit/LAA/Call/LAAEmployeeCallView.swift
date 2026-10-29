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
            LinearGradient(colors: [Color(red: 0, green: 0.34, blue: 0.37),
                                    Color(red: 0.05, green: 0.10, blue: 0.11)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if let snapshot = calls.snapshot {
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer(minLength: 32)
                        avatar(snapshot)
                        VStack(spacing: 8) {
                            Text(snapshot.context.name)
                                .font(.custom("Georgia", size: 32, relativeTo: .title))
                                .accessibilityIdentifier("laa.call.name")
                            status(snapshot)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                                .accessibilityIdentifier("laa.call.status")
                        }
                        Spacer(minLength: 32)
                        controls(snapshot)
                            .padding(.bottom, 28)
                    }
                    .frame(maxWidth: 540, minHeight: 620)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .foregroundStyle(.white)
        .accessibilityIdentifier("laa.call.screen")
        .interactiveDismissDisabled()
        .onAppear { routeLabel = LAAAudioRouteLabel.current() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)) { _ in
                routeLabel = LAAAudioRouteLabel.current()
            }
    }

    private func avatar(_ snapshot: LAAEmployeeCallSnapshot) -> some View {
        let level = Self.level(snapshot.audioLevel)
        return ZStack {
            Circle()
                .stroke(.white.opacity(0.45), lineWidth: 2)
                .frame(width: 278, height: 278)
                .scaleEffect(reduceMotion ? 1 : 1 + CGFloat(level) * 0.08)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
            StaffAvatarView(profile: snapshot.context.profile, name: snapshot.context.name, size: 270)
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
                    Text(verbatim: routeLabel).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
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
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
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
        picker.tintColor = .white
        picker.activeTintColor = .white
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

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(destructive ? Color.red : (selected ? Color.white.opacity(0.35) : Color(red: 0.09, green: 0.15, blue: 0.16)), in: Circle())
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.clear.tint(destructive ? .red.opacity(0.75) : (selected ? .white.opacity(0.25) : .clear)).interactive(), in: Circle())
        } else if destructive {
            content.background(.ultraThinMaterial, in: Circle()).background(Color.red.opacity(0.65), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

struct LAACallPresentation: ViewModifier {
    @ObservedObject var calls: LAAEmployeeCallCoordinator
    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $calls.isShowingCall) {
            LAAEmployeeCallView(calls: calls)
                .preferredColorScheme(.dark)
        }
    }
}

struct LAAInCallBar: View {
    @ObservedObject var calls: LAAEmployeeCallCoordinator
    let profile: String
    let conversationID: String?

    var body: some View {
        if let snapshot = calls.snapshot,
           snapshot.phase.isOngoing,
           !calls.isShowingCall,
           snapshot.context.profile == profile,
           snapshot.context.conversationID == conversationID {
            Button(action: calls.showCall) {
                HStack(spacing: 8) {
                    Image(systemName: "phone.fill")
                    Text(verbatim: "\(snapshot.context.name) と通話中")
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
