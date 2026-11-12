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

/// One Work message in the chat's form: the owner's bubble trailing with the
/// owner's picture, name and role; the AI's leading with its name.
struct LAAWorkMessageRow: View {
    let message: LAAWorkConversationMessage
    let sessionID: String
    let agentName: String
    let continues: Bool
    let responseSize: Int
    /// The model the AI turns are drawn with (its face beside the name).
    var model: LAAWorkModel? = nil
    /// Puts this message into the follow-up field as a quote.
    var onQuote: ((String) -> Void)? = nil

    private var isOwner: Bool { message.role == "user" }

    var body: some View {
        Group {
            if isOwner {
                LAAOwnerMessageRow(continues: continues) {
                    VStack(alignment: .trailing, spacing: 0) {
                        bubble
                        HStack(spacing: 2) {
                            LAAMessageTime(timestamp: message.timestamp)
                            actions
                        }
                    }
                }
            } else {
                // Every reply names its model, the in-between progress notes
                // too (owner, 2026-11-12): a run does not fold the header.
                LAAAgentMessageRow(name: agentName, continues: false) {
                    LAAModelMark(model: model?.model, provider: model?.provider)
                } content: {
                    VStack(alignment: .leading, spacing: 0) {
                        bubble
                        HStack(spacing: 2) {
                            actions.padding(.leading, -8)
                            LAAMessageTime(timestamp: message.timestamp)
                        }
                    }
                }
            }
        }
        // The sender row leaves the other side's gap itself; a second,
        // narrower column here pushed both sides toward the middle.
        .frame(maxWidth: .infinity, alignment: isOwner ? .trailing : .leading)
    }

    private var actions: some View {
        LAAWorkMessageActions(text: message.text, sessionID: sessionID, messageID: message.id,
                              isOwner: isOwner, onQuote: onQuote)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            if !message.text.isEmpty {
                // A short turn keeps a short bubble, as in the chat.
                HugsIdealWidth {
                    // The render cache knows two inks: white on the accent
                    // bubble (as the chat's own messages) and LAA text.
                    MarkdownText(source: message.text,
                                 foregroundStyle: isOwner ? .white : LAAColor.text,
                                 usesAccentSurface: isOwner)
                }
                .environment(\.chatTextSize, ChatTextAppearance(size: ChatTypography.resolve(rawValue: responseSize), style: .standard))
            }
            ForEach(message.images ?? [], id: \.self) { imageID in
                LAAWorkSessionImage(sessionID: sessionID, imageID: imageID)
            }
        }
        .padding(LAASpacing.x4)
        .foregroundStyle(isOwner ? LAAColor.ownBubbleText : LAAColor.text)
        .background(isOwner ? LAAColor.ownBubble : LAAColor.surface,
                    in: RoundedRectangle(cornerRadius: LAARadius.bubble, style: .continuous))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: LAARadius.bubble, style: .continuous))
        .modifier(LAAWorkMessageMenu(text: message.text, sessionID: sessionID, messageID: message.id,
                                     isOwner: isOwner, onQuote: onQuote))
    }
}
#endif
