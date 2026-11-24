#if LAA_BUILD
import SwiftUI

/// Who speaks in a Work conversation. The Bridge's session names no employee,
/// so the AI is the model it runs on; nothing here guesses an employee.
enum LAAWorkSpeaker {
    static func speaker(_ message: LAAWorkConversationMessage) -> LAASenderRun.Speaker {
        switch message.role {
        case "user": return .owner
        case "assistant": return .agent
        default: return .other
        }
    }

    /// Use the applied model and effort when the daemon has reported both.
    static func agentName(_ session: LAAWorkSession, options: LAAWorkSessionOptions?) -> String {
        LAAWorkSessionStyle.appliedModel(session, options: options) ?? "AI"
    }

    /// The name above one reply: the model the Bridge saw writing it
    /// ("Fable 5.2"), else only the provider ("Claude"). The session's current
    /// model is never lent to an earlier reply: it may have been another one.
    static func replyName(_ message: LAAWorkConversationMessage, session: LAAWorkSession,
                          options: LAAWorkSessionOptions?) -> String {
        let provider = message.model?.provider ?? session.observed?.provider ?? session.requested?.provider
        if let name = LAAWorkSessionStyle.modelName(message.model?.model, provider: provider, options: options) { return name }
        return LAAWorkSessionStyle.providerName(provider, model: message.model?.model)
            ?? LAAWorkSessionStyle.providerName(provider, model: (session.observed ?? session.requested)?.model)
            ?? "AI"
    }

    /// The face beside it: the reply's own model, else the provider's face.
    static func replyModel(_ message: LAAWorkConversationMessage, session: LAAWorkSession) -> LAAWorkModel {
        if let model = message.model, model.model?.isEmpty == false { return model }
        let provider = session.observed?.provider ?? session.requested?.provider
        return LAAWorkModel(provider: provider, model: nil, effort: nil, sources: nil)
    }
}

/// One Work message in the shared transcript (LAATranscript), the same rows
/// the employee Chat draws: the owner's soft bubble trailing under the
/// owner's speaker line; the AI's words on the paper under its model's line.
struct LAAWorkMessageRow: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let message: LAAWorkConversationMessage
    let sessionID: String
    let agentName: String
    let continues: Bool
    let responseSize: Int
    /// The model the AI turns are drawn with (its face beside the name).
    var model: LAAWorkModel? = nil
    /// Puts this message into the follow-up field as a quote.
    var onQuote: ((String) -> Void)? = nil
    /// The session's folder on the Mac: a relative path a reply names is
    /// read from there.
    var cwd: String? = nil

    private var isOwner: Bool { message.role == "user" }

    var body: some View {
        Group {
            if isOwner {
                LAATranscriptOwnerTurn(continues: continues, timestamp: message.timestamp) {
                    VStack(alignment: .trailing, spacing: 0) {
                        content.laaTranscriptOwnerBubble()
                        actions.padding(.trailing, -8)
                    }
                }
            } else {
                // Every reply names its model, the in-between progress notes
                // too (owner, 2026-11-12): a run does not fold the header.
                LAATranscriptAgentTurn(name: agentName, continues: false, timestamp: message.timestamp) {
                    LAAModelMark(model: model?.model, provider: model?.provider, size: LAATranscriptMetrics.avatar)
                } content: {
                    VStack(alignment: .leading, spacing: 0) {
                        content
                        actions.padding(.leading, -8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isOwner ? .trailing : .leading)
    }

    private var actions: some View {
        LAAWorkMessageActions(text: message.text, sessionID: sessionID, messageID: message.id,
                              isOwner: isOwner, onQuote: onQuote)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: LAATranscriptMetrics.rowGap) {
            if !message.text.isEmpty {
                // A short turn keeps a short bubble, as in the chat.
                HugsIdealWidth {
                    // Mac paths become links a tap opens; the AI's `MEDIA:`
                    // files and `::preview` pages are read from the Mac
                    // through the Bridge (`LAAWorkFiles`), not from Hermes.
                    MarkdownText(source: LAAFileLinks.linkified(message.text) { [cwd] in LAAFileLinks.workLink($0, cwd: cwd) },
                                 foregroundStyle: LAAColor.text,
                                 gatewayMediaDataURL: isOwner ? nil : { [bridge, sessionID] path in
                                     await LAAWorkFiles.dataURL(bridge: bridge, sessionID: sessionID, path: path)
                                 })
                }
                .environment(\.chatTextSize, LAAReadingStyle.reading(ChatTextAppearance(size: ChatTypography.resolve(rawValue: responseSize), style: .standard)))
            }
            ForEach(message.images ?? [], id: \.self) { imageID in
                LAAWorkSessionImage(sessionID: sessionID, imageID: imageID)
            }
        }
        .foregroundStyle(LAAColor.text)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: LAATranscriptMetrics.ownerBubbleRadius, style: .continuous))
        .modifier(LAAWorkFileLinkOpener(sessionID: sessionID))
    }
}
#endif
