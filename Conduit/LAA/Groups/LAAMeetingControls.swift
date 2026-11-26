#if LAA_BUILD
import SwiftUI

/// Observes just the meeting strip; audio level updates do not invalidate the
/// room's transcript or composer.
struct LAAMeetingControls: View {
    @ObservedObject var meeting: LAAMeetingSession
    @ObservedObject private var audio = VoiceAudioSessionCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var talkFocused: Bool
    @State private var spaceHeld = false

    let members: [GroupMember]
    let queue: () -> LAAChairedVoicePlayback
    let hasCompetingAudio: () -> Bool
    let talk: () -> Void
    let releaseTalk: () -> Void
    let mute: () -> Void
    let skip: () -> Void
    let end: () -> Void
    let stop: () -> Void
    let ownerChanged: () -> Void

    var body: some View {
        let queue = queue()
        let speakerID = queue.current?.utterance.speakerID
        let speaker = members.first { speakerID != nil && ($0.profile == speakerID || $0.memberID == speakerID) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                LAAParticleOrbView(size: 36, level: meeting.turn.ownerTalking ? meeting.micLevel : meeting.speechLevel,
                    thinking: meeting.turn.phase == .waiting || meeting.turn.ownerTalking ? 1 : 0,
                    ground: colorScheme == .dark ? .dark : .paperBead)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: speaker?.displayName ?? status(speaking: speakerID != nil))
                        .laaTextStyle(.note)
                        .accessibilityIdentifier("laa.room.voice.status")
                    if let note = meeting.note {
                        Text(verbatim: note).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    }
                }
                Spacer(minLength: 0)
                ForEach(Array(members.filter { $0.memberID != nil }.prefix(5)), id: \.memberID) { member in
                    let isSpeaking = speakerID != nil && (member.profile == speakerID || member.memberID == speakerID)
                    StaffMascotView(profile: member.profile ?? "", name: member.displayName ?? member.handle ?? "",
                                    size: 24, level: isSpeaking ? Float(meeting.speechLevel) : 0)
                        .opacity(speakerID == nil || isSpeaking ? 1 : 0.5)
                        .accessibilityHidden(true)
                }
            }
            if !meeting.captions.isEmpty {
                Text(verbatim: meeting.captions.joined(separator: "\n"))
                    .laaTextStyle(.secondary).lineLimit(2)
                    .accessibilityIdentifier("laa.room.voice.captions")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons(queue) }
                VStack(alignment: .leading, spacing: 8) { buttons(queue) }
            }
            .padding(.horizontal, 8)
            .conduitGlassControl(cornerRadius: 22, tint: .clear)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-LAA_MEETING_DIAGNOSTICS") {
                Text(verbatim: "otherAudio=\(audio.meetingOtherAudioPlaying) policy=\(audio.appliedPolicy.map { String(describing: $0) } ?? "inactive") lease=\(meeting.endpoint.generation ?? "none")")
                    .laaTextStyle(.note).accessibilityIdentifier("laa.room.voice.diagnostics")
            }
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laa.room.voice")
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { spaceHeld = false; stop() }
        }
        .onChange(of: audio.isInNativeCall) { _, _ in ownerChanged() }
        .onChange(of: audio.appliedPolicy) { _, _ in ownerChanged() }
        .onChange(of: talkFocused) { _, focused in
            if !focused, spaceHeld { spaceHeld = false; releaseTalk() }
        }
    }

    @ViewBuilder
    private func buttons(_ queue: LAAChairedVoicePlayback) -> some View {
        let engaged = queue.phase != .silent
        let talking = meeting.turn.ownerTalking
        let talkButton = button(meeting.claiming ? "接続を中止" : talking ? "話し終える" : "話す",
                                symbol: talking ? "mic.fill" : "mic",
                                id: "talk", action: (talking || meeting.claiming) ? releaseTalk : talk)
        #if targetEnvironment(macCatalyst)
        talkButton.focused($talkFocused)
            .accessibilityHint(Text(verbatim: "フォーカス中はスペースキーを押している間だけ話します。"))
            .onKeyPress(.space, phases: [.down, .up, .repeat]) { key in
                if key.phase == .down, !spaceHeld { spaceHeld = true; talk() }
                if key.phase == .up, spaceHeld { spaceHeld = false; releaseTalk() }
                return .handled
            }
            .disabled(hasCompetingAudio())
        #else
        talkButton.disabled(hasCompetingAudio())
        #endif
        button(queue.muted ? "消音解除" : "消音", symbol: queue.muted ? "speaker.slash.fill" : "speaker.slash",
               id: "stop", action: mute).disabled(!engaged)
        button("次へ", symbol: "forward.end", id: "skip", action: skip).disabled(queue.current == nil)
        button("終了", symbol: "stop", id: "end", action: end).disabled(!engaged)
    }

    private func button(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
                .laaTextStyle(.note)
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("laa.room.voice.\(id)")
    }

    private func status(speaking: Bool) -> String {
        if speaking { return "発言中" }
        if meeting.claiming { return "音声に接続中" }
        if meeting.turn.ownerTalking { return "あなたの番" }
        switch meeting.turn.phase {
        case .idle: return "壁打ち Voice"
        case .listening: return "聞く"
        case .sending: return "発言を確認して送信"
        case .waiting, .speaking: return "応答を待っています"
        }
    }
}
#endif
