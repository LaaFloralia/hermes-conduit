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

    /// "Opus 5.5" from the model table, else the model the Mac reports, else "AI".
    static func agentName(_ session: LAAWorkSession, options: LAAWorkSessionOptions?) -> String {
        if let profile = options?.profiles.first(where: { $0.id == session.profile }) {
            return LAAWorkSessionStyle.shortLabel(profile.label)
        }
        if let model = session.observed?.model ?? session.requested?.model, !model.isEmpty {
            let label = options?.profiles.first { $0.model == model }?.label
            return LAAWorkSessionStyle.displayModel(label ?? model)
        }
        return "AI"
    }
}

/// One Work message in the chat's form: the owner's bubble trailing with the
/// owner's picture, name and role; the AI's leading with its name.
struct LAAWorkMessageRow: View {
    let message: LAAWorkConversationMessage
    let sessionID: String
    let agentName: String
    let continues: Bool
    /// The reading column; nil until the screen has been measured.
    let columnWidth: CGFloat?
    let responseSize: Int

    private var isOwner: Bool { message.role == "user" }

    var body: some View {
        Group {
            if isOwner {
                LAAOwnerMessageRow(continues: continues) {
                    VStack(alignment: .trailing, spacing: LAASpacing.x1) {
                        bubble
                        LAAMessageTime(timestamp: message.timestamp)
                    }
                }
            } else {
                LAAAgentMessageRow(name: agentName, continues: continues) {
                    LAAAgentPlaceholderAvatar()
                } content: {
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        bubble
                        LAAMessageTime(timestamp: message.timestamp)
                    }
                }
            }
        }
        .frame(maxWidth: columnWidth ?? .infinity, alignment: isOwner ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: isOwner ? .trailing : .leading)
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
    }
}
#endif
