#if LAA_BUILD
import SwiftUI
import WatchKit
import UIKit

/// Lines the Watch says in more than one place: the ask screen and the
/// polling timeout, so the two cannot drift.
enum LAAWatchCopy {
    static let stillWorking = "作業中です。返事はiPhoneのChatに届きます"
    static let notConnected = "iPhoneに接続できません。"
}

private extension View {
    @ViewBuilder func laaPrimaryAction() -> some View {
        if #available(watchOS 11, *) { handGestureShortcut(.primaryAction) }
        else { self }
    }
}

private struct LAAWatchAvatar: View {
    let staff: LAAStaff
    var size: CGFloat = 60
    var body: some View {
        Group {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("staff/\(staff.rawValue).png"),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text(String(staff.name.prefix(1))).font(.title2.weight(.semibold))
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.09), in: Circle())
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

struct LAAWatchHome: View {
    @StateObject private var voice = LAAWatchVoice.shared
    @Environment(\.watchAccent) private var accent
    @State private var fixtureEmployee = false
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Button { voice.openDefault() } label: {
                    HStack {
                        LAAWatchAvatar(staff: LAAStaff.allCases[0], size: 30)
                        Image(systemName: "mic.fill")
                        Text(verbatim: "Talk").fontWeight(.semibold)
                    }.frame(maxWidth: .infinity)
                }
                .tint(accent)
                .laaPrimaryAction()
                .accessibilityLabel(Text(verbatim: "Talk, \(LAAStaff.allCases[0].name)"))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(LAAStaff.allCases, id: \.rawValue) { staff in
                        NavigationLink { LAAWatchEmployee(staff: staff) } label: {
                            VStack(spacing: 3) {
                                LAAWatchAvatar(staff: staff)
                                Text(staff.name).font(.caption).lineLimit(1)
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(.plain).accessibilityLabel(staff.name)
                    }
                }
            }
        }
        .navigationDestination(isPresented: $fixtureEmployee) { LAAWatchEmployee(staff: LAAStaff.allCases[0]) }
        .onAppear {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "-laaWatchFixture"), index + 1 < args.count, args[index + 1] == "employee" { fixtureEmployee = true }
            #endif
        }
        .navigationTitle(Text(verbatim: "LAA"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { WatchSettingsView() } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings") } }
        .watchBackdrop()
        .sheet(isPresented: $voice.showing, onDismiss: { voice.cancel() }) { LAAWatchRecording().environmentObject(voice) }
    }
}

private struct LAAWatchEmployee: View {
    let staff: LAAStaff
    @ObservedObject private var voice = LAAWatchVoice.shared
    @ObservedObject private var link = WatchLink.shared
    @Environment(\.watchAccent) private var accent
    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                LAAWatchAvatar(staff: staff, size: 84)
                Text(staff.name).font(.headline)
                Text(staff.role).font(.caption2).foregroundStyle(.secondary)
                HStack {
                    if link.phoneContext?.laaCallableProfiles?.contains("laa-\(staff.rawValue)") ?? true {
                        Button { WatchVoiceCall.shared.startEmployee(staff) } label: { Label { Text(verbatim: "Call") } icon: { Image(systemName: "phone.fill") } }.tint(.green)
                    }
                    Button { voice.open(staff) } label: { Label { Text(verbatim: "Talk") } icon: { Image(systemName: "mic.fill") } }
                        .tint(accent)
                        .highPriorityGesture(LongPressGesture().onEnded { _ in voice.open(staff, textOnly: true) })
                }.font(.caption2)
                if let recent = voice.recent["laa-\(staff.rawValue)"] {
                    NavigationLink {
                        ScrollView { VStack(alignment: .leading) { Text(recent.transcript ?? ""); Text(recent.reply ?? "") } }.navigationTitle(staff.name)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(recent.transcript ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(recent.reply ?? "").font(.body).lineLimit(3)
                        }
                    }
                }
            }
        }.navigationTitle(staff.name).navigationBarTitleDisplayMode(.inline).watchBackdrop()
    }
}

private struct LAAWatchRecording: View {
    @EnvironmentObject private var voice: LAAWatchVoice
    @Environment(\.watchAccent) private var accent
    @Environment(\.isLuminanceReduced) private var reduced
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    HStack { LAAWatchAvatar(staff: voice.staff, size: 30); Text(voice.staff.name).font(.headline) }
                    if voice.recording {
                        Image(systemName: "mic.fill").font(.title)
                            .frame(width: 64, height: 64).background(accent, in: Circle())
                            .scaleEffect(reduced ? 1 : 1 + CGFloat(min(voice.level, 0.3)))
                            .accessibilityLabel(Text(verbatim: "録音中"))
                        Text(verbatim: "0:\(String(format: "%02d", voice.elapsed)) / 0:\(LAAWatchAsk.maxSeconds)").font(.caption.monospacedDigit())
                        Button("Done") { voice.done() }.tint(accent).laaPrimaryAction()
                        Button { voice.showTextEntry() } label: { Text(verbatim: "Aa") }.accessibilityLabel(Text(verbatim: "文字入力"))
                    } else if let state = voice.state {
                        if state.phase == .answered, let transcript = state.transcript, !transcript.isEmpty {
                            Text(transcript).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(message(state)).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                        if state.phase.isFinal { Button { Task { await voice.start() } } label: { Text(verbatim: "もう一度") }.tint(accent) }
                    } else { ProgressView() }
                }
            }
            .navigationTitle(Text(verbatim: "Talk")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { voice.cancel(); voice.showing = false } label: { Text(verbatim: "Cancel") } } }
            .sheet(isPresented: $voice.textEntry, onDismiss: {
                if voice.showing && !voice.recording && voice.state == nil { Task { await voice.start() } }
            }) {
                VStack {
                    TextField(text: $voice.typed) { Text(verbatim: "メッセージ") }
                    Button("Done") { voice.sendText() }.disabled(voice.typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voice.typed.count > LAAWatchAsk.maxTextLength)
                }.padding()
            }
            .watchBackdrop()
        }
    }
    private func message(_ state: LAAWatchAsk.State) -> String {
        switch state.phase {
        case .received, .transcribing: return "文字にしています"
        case .sending: return "送っています"
        case .answered: return state.reply ?? "返事がありません"
        case .stillWorking, .queued: return LAAWatchCopy.stillWorking
        case .needsInput: return "iPhoneのChatで返事を待っています"
        case .silent: return "音声がありません"
        case .failed: return state.failure ?? "送信できませんでした"
        case .unknown: return "iPhoneのChatを確認してください"
        }
    }
}
#endif
