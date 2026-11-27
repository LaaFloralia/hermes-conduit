#if LAA_BUILD
import LAAKit
import SwiftUI

/// Observes just the meeting strip; audio level updates do not invalidate the
/// room's transcript or composer.
struct LAAMeetingControls: View {
    @ObservedObject var meeting: LAAMeetingSession
    @ObservedObject private var audio = VoiceAudioSessionCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var talkFocused: Bool
    @State private var spaceHeld = false

    let members: [GroupMember]
    let queue: () -> LAAChairedVoicePlayback
    let hasCompetingAudio: () -> Bool
    let talk: @MainActor () async -> Void
    let releaseTalk: () -> Void
    let mute: () -> Void
    let skip: () -> Void
    let end: () -> Void
    let stop: () -> Void
    let ownerChanged: () -> Void

    /// Kit orb state: listening while the owner talks, thinking while a staff reply is awaited, speaking while
    /// a staff line plays.
    private func orbState(speaking: Bool) -> LAAParticleOrb.State {
        if meeting.turn.ownerTalking { return .listening }
        switch meeting.turn.phase {
        case .listening: return .listening
        case .sending, .waiting: return .thinking
        case .speaking: return .speaking
        case .idle: return speaking ? .speaking : .idle
        }
    }

    var body: some View {
        let queue = queue()
        let speakerID = queue.current?.utterance.speakerID
        let speaker = members.first { speakerID != nil && ($0.profile == speakerID || $0.memberID == speakerID) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                LAAParticleOrb(size: 36, state: orbState(speaking: speakerID != nil),
                               level: meeting.turn.ownerTalking ? meeting.micLevel : meeting.speechLevel)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: speakerID.map { LAACopy.GroupVoice.speaking(speaker?.displayName ?? speaker?.handle ?? $0) } ?? status)
                        .laaTextStyle(.note)
                        .accessibilityIdentifier("laa.room.voice.status")
                    if let note = meeting.note {
                        Text(verbatim: note).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    }
                }
                Spacer(minLength: 0)
                ForEach(members.filter { $0.memberID != nil }, id: \.memberID) { member in
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
            .conduitGlassControl(cornerRadius: 12, tint: .clear)
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
        let talkButton = button(meeting.claiming ? LAACopy.GroupVoice.cancelConnection : talking ? LAACopy.GroupVoice.finish : LAACopy.GroupVoice.talk,
                                symbol: talking ? "mic.fill" : "mic", id: "talk") {
            if talking || meeting.claiming { releaseTalk() } else { Task { await talk() } }
        }
        #if targetEnvironment(macCatalyst)
        talkButton.focused($talkFocused)
            .accessibilityHint(Text(verbatim: "フォーカス中はスペースキーを押している間だけ話します。"))
            .onKeyPress(.space, phases: [.down, .up, .repeat]) { key in
                if key.phase == .down, !spaceHeld {
                    spaceHeld = true
                    Task { @MainActor in if spaceHeld { await talk() } }
                }
                if key.phase == .up, spaceHeld { spaceHeld = false; releaseTalk() }
                return .handled
            }
            .disabled(hasCompetingAudio())
        #else
        talkButton.disabled(hasCompetingAudio())
        #endif
        button(queue.muted ? LAACopy.GroupVoice.unmute : LAACopy.GroupVoice.mute, symbol: queue.muted ? "speaker.slash.fill" : "speaker.slash",
               id: "stop", action: mute).disabled(!engaged)
        button(LAACopy.GroupVoice.skip, symbol: "forward.end", id: "skip", action: skip).disabled(queue.current == nil)
        button(LAACopy.GroupVoice.end, symbol: "stop", id: "end", action: end).disabled(!engaged)
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

    private var status: String {
        if meeting.claiming { return LAACopy.GroupVoice.connecting }
        if meeting.turn.ownerTalking { return LAACopy.GroupVoice.ownerTurn }
        switch meeting.turn.phase {
        case .idle, .listening: return LAACopy.GroupVoice.title
        case .sending: return LAACopy.GroupVoice.review
        case .waiting, .speaking: return LAACopy.GroupVoice.waiting
        }
    }
}
#endif
