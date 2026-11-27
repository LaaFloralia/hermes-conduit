#if LAA_BUILD
import SwiftUI

/// The chaired room's Voice / Talk / Stop controls, above the composer.
/// Draws `state` and calls `actions` only from a button tap: nothing runs
/// on appear, so opening the room, launch, or a preview stays silent and
/// never touches the microphone or the audio session.
struct LAAChairedVoiceBar: View {
    let state: LAAChairedVoiceSurfaceState
    let actions: LAAChairedVoiceActions
    /// Called after each action so the host re-reads the binding's state
    /// (the binding is not observable on its own).
    var onAction: () -> Void = {}
    /// The last refusal of an explicit Voice tap, shown until the next tap.
    @State private var refusal: LAAChairedVoiceRefusal?

    var body: some View {
        if state != .hidden {
            VStack(alignment: .leading, spacing: 6) {
                // Large text: the row wraps to a column instead of truncating.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { controls }
                    VStack(alignment: .leading, spacing: 8) { controls }
                }
                if let note {
                    Text(verbatim: note)
                        .laaTextStyle(.secondary)
                        .foregroundStyle(LAAColor.attention)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("laa.room.voice.note")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("laa.room.voice")
        }
    }

    private var note: String? {
        if state == .staffCallOwnsAudio { return LAAChairedVoiceCopy.staffCall }
        return refusal.map(LAAChairedVoiceCopy.refusal)
    }

    @ViewBuilder
    private var controls: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .off, .staffCallOwnsAudio:
            Button {
                refusal = actions.engage()
                onAction()
            } label: {
                Label { Text(verbatim: LAAChairedVoiceCopy.voice) } icon: { Image(systemName: "speaker.wave.2") }
            }
            .laaButton(.secondary)
            .disabled(state == .staffCallOwnsAudio)
            .accessibilityHint(Text(verbatim: state == .staffCallOwnsAudio
                ? LAAChairedVoiceCopy.staffCall : LAAChairedVoiceCopy.voiceHint))
            .accessibilityIdentifier("laa.room.voice.engage")
        case .listening, .talking:
            Text(verbatim: state == .talking ? LAAChairedVoiceCopy.talking : LAAChairedVoiceCopy.listening)
                .laaTextStyle(.note).fontWeight(.semibold)
                .foregroundStyle(LAAColor.link)
                .accessibilityIdentifier("laa.room.voice.status")
            if state == .listening {
                Button {
                    refusal = nil
                    actions.talk()
                    onAction()
                } label: {
                    Label { Text(verbatim: LAAChairedVoiceCopy.talk) } icon: { Image(systemName: "mic") }
                }
                .laaButton(.secondary)
                .accessibilityHint(Text(verbatim: LAAChairedVoiceCopy.talkHint))
                .accessibilityIdentifier("laa.room.voice.talk")
            } else {
                Button {
                    refusal = nil
                    actions.talkEnded()
                    onAction()
                } label: {
                    Label { Text(verbatim: LAAChairedVoiceCopy.listen) } icon: { Image(systemName: "speaker.wave.2") }
                }
                .laaButton(.secondary)
                .accessibilityHint(Text(verbatim: LAAChairedVoiceCopy.listenHint))
                .accessibilityIdentifier("laa.room.voice.listen")
            }
            Button {
                refusal = nil
                actions.stop()
                onAction()
            } label: {
                Label { Text(verbatim: LAAChairedVoiceCopy.stop) } icon: { Image(systemName: "stop") }
            }
            .laaButton(.text)
            .accessibilityHint(Text(verbatim: LAAChairedVoiceCopy.stopHint))
            .accessibilityIdentifier("laa.room.voice.stop")
        }
    }
}

#Preview("Voice") {
    // Inert actions: a preview never engages, so no mic and no TTS.
    VStack(spacing: 12) {
        LAAChairedVoiceBar(state: .off, actions: .inert)
        LAAChairedVoiceBar(state: .listening, actions: .inert)
        LAAChairedVoiceBar(state: .talking, actions: .inert)
        LAAChairedVoiceBar(state: .staffCallOwnsAudio, actions: .inert)
    }
}
#endif
