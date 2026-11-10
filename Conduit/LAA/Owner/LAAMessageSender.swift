#if LAA_BUILD
import SwiftUI

/// Who said a message, the same way in Chat, groups and Work: the speaker's
/// 30 pt picture beside the bubble and the name above it, once per run of
/// messages. AI speakers lead on the left; the owner trails on the right,
/// with the square role label only the owner carries.
enum LAASender {
    /// The group chat's member picture (`GroupMemberBubble.avatarSize`).
    static let avatarSize: CGFloat = 30
    static let avatarSpacing: CGFloat = 9
    static let headerSpacing: CGFloat = 3
    /// Small, so the label reads as a square plate rather than a pill.
    static let badgeCornerRadius: CGFloat = 4

    /// The employee's name as the chat's header shows it.
    static func agentName(profile: String, identity: ConversationAgentIdentity) -> String {
        LAAStaff(profile: profile)?.name ?? (profile == "default" ? LAACopy.agent : identity.name)
    }
}

/// The speaker's name above a bubble, in the group chat's name style.
struct LAASenderName: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .font(LAAType.title(text, size: 15, relativeTo: .caption))
            .foregroundStyle(LAAColor.secondaryText)
            .lineLimit(1)
            .laaPhotoSupportingText()
    }
}

/// "Administration", beside the owner's name only.
struct LAAAdministrationBadge: View {
    var body: some View { LAARoleBadge(role: LAAOwnerIdentity.role) }
}

/// The owner's name and role, read by VoiceOver as "LAA、Administration".
struct LAAOwnerHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            LAASenderName(text: LAAOwnerIdentity.name)
            LAAAdministrationBadge()
        }
        // One phrase in place of the two texts, so the role is never a
        // second element of its own.
        .accessibilityRepresentation { Text(verbatim: LAAOwnerIdentity.spokenHeader) }
        .accessibilityIdentifier("chat.sender.owner")
    }
}

/// An owner's message: the header above, the picture beside it on the
/// trailing side. `continues` drops both for the next message in a run, and
/// keeps the bubble's edge where the first one's was.
struct LAAOwnerMessageRow<Content: View>: View {
    var continues = false
    var timestamp: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !continues {
                HStack(spacing: 8) {
                    LAAMessageTime(timestamp: timestamp)
                    LAAAdministrationBadge()
                    LAASenderName(text: LAAOwnerIdentity.name)
                    LAAOwnerAvatarView().frame(width: 30, height: 30)
                }.accessibilityIdentifier("chat.sender.owner")
            }
            content.frame(maxWidth: 332, alignment: .trailing).padding(.trailing, 40)
        }.frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct LAAAgentMessageRow<Avatar: View, Content: View>: View {
    let name: String
    var continues = false
    var role: String? = nil
    var timestamp: String? = nil
    @ViewBuilder let avatar: Avatar
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !continues {
                HStack(spacing: 8) {
                    avatar.frame(width: 30, height: 30).accessibilityHidden(true)
                    LAASenderName(text: name)
                    if let role { LAARoleBadge(role: role) }
                    LAAMessageTime(timestamp: timestamp)
                }.accessibilityIdentifier("chat.sender.agent")
            }
            content.frame(maxWidth: 332, alignment: .leading).padding(.leading, 40)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A neutral face for an AI that has no employee mascot: the model is named
/// beside it, and nothing about the picture claims an employee.
struct LAAAgentPlaceholderAvatar: View {
    var size: CGFloat = LAASender.avatarSize
    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(LAAColor.link)
            .frame(width: size, height: size)
            .background(LAAColor.selectionFill, in: Circle())
            .overlay { Circle().strokeBorder(LAAColor.separator, lineWidth: 0.5) }
    }
}

/// Which rows start a run. A row continues the run when the row right
/// before it is the same speaker's message bubble.
enum LAASenderRun {
    enum Speaker: Equatable { case owner, agent, other }

    static func continues(_ speakers: [Speaker], at index: Int) -> Bool {
        guard index > 0, speakers.indices.contains(index), speakers[index] != .other else { return false }
        return speakers[index - 1] == speakers[index]
    }

    /// The chat transcript's rows: steps (thinking, tools) break a run, so the
    /// reply after them names its speaker again.
    static func speaker(of target: ChatMessageScrollTarget) -> Speaker {
        guard target.step == nil, !target.isStep else { return .other }
        switch target.message.role {
        case .user: return target.message.isSteer ? .other : .owner
        case .assistant: return .agent
        default: return .other
        }
    }

    /// The previous visible row, found by order like the day separator.
    static func continues(_ target: ChatMessageScrollTarget, in visible: [ChatMessageScrollTarget]) -> Bool {
        let speaker = speaker(of: target)
        guard speaker != .other else { return false }
        var lower = 0, upper = visible.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if visible[middle].order < target.order { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return false }
        return self.speaker(of: visible[lower - 1]) == speaker
    }
}

private struct LAASenderContinuesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set per chat row: the row before it is the same speaker's bubble.
    var laaSenderContinues: Bool {
        get { self[LAASenderContinuesKey.self] }
        set { self[LAASenderContinuesKey.self] = newValue }
    }
}

/// A message's time under its bubble, in the chat's style.
struct LAAMessageTime: View {
    let timestamp: String?
    var body: some View {
        if let timestamp, let label = MessageTimestampFormatter.displayString(for: timestamp) {
            Text(verbatim: label)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .laaPhotoSupportingText()
                .foregroundStyle(LAAColor.secondaryText)
        }
    }
}
#endif
