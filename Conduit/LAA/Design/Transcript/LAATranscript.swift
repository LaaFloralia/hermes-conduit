#if LAA_BUILD
import LAAKit
import SwiftUI

/// One transcript for every LAA conversation: the employee Chat and the Work
/// Session, on the iPhone and the Mac (P0-7, ADVICE-V2 §3.5). The owner's
/// words sit in a soft trailing bubble; an employee's or an agent's words are
/// set straight on the paper under a speaker line, as a page of a book.
enum LAATranscriptMetrics {
    /// Catalyst draws UIKit points at 0.77 Mac points; the tokens are Mac
    /// points on the Mac (`LAAReadingStyle.platformScale`).
    static var scale: CGFloat { LAAReadingStyle.platformScale }

    private typealias Tokens = LAAComponentToken.Transcript
    static let ownerBubbleRadius: CGFloat = Tokens.bubbleRadius
    static var ownerBubblePaddingV: CGFloat { Tokens.bubblePaddingV * scale }
    static var ownerBubblePaddingH: CGFloat { Tokens.bubblePaddingH * scale }
    static let ownerBubbleShare: CGFloat = Tokens.bubbleMaxWidth
    static var ownerBubbleMacMax: CGFloat { Tokens.bubbleMaxWidthMac * scale }

    static var avatar: CGFloat { Tokens.mascot * scale }
    static var speakerSpacing: CGFloat { Tokens.speakerGap * scale }
    static var speakerNameSize: CGFloat { Tokens.speakerName * scale }
    static var speakerRoleSize: CGFloat { Tokens.speakerRole * scale }
    static var speakerToProse: CGFloat { Tokens.speakerGap * scale }
    static var turnGap: CGFloat { Tokens.turnGap * scale }
    static var rowGap: CGFloat { Tokens.paragraphGap * scale }

    static var thoughtOrb: CGFloat { LAAComponentToken.WorkingStrip.iphone.orb * scale }
    static var thoughtTextSize: CGFloat { LAAType.canvas.small * scale }
    static var thoughtMinHeight: CGFloat { LAAControl.Mac.iconButton.visual * scale }

    /// The widest the prose runs: the Mac's 680 pt measure, left-anchored.
    static var proseMeasure: CGFloat? {
        #if targetEnvironment(macCatalyst)
        LAAReadingStyle.macMeasure
        #else
        nil
        #endif
    }

    /// The owner's bubble in a column `column` wide.
    static func ownerBubbleMaxWidth(column: CGFloat) -> CGFloat {
        #if targetEnvironment(macCatalyst)
        min(ownerBubbleMacMax, max(1, column * ownerBubbleShare))
        #else
        max(1, (column * ownerBubbleShare).rounded(.down))
        #endif
    }
}

/// Offers its content at most the owner's share of the width it is offered
/// (`LAATranscriptMetrics.ownerBubbleMaxWidth`), whatever column it sits in,
/// and puts it at the trailing edge. It takes the whole offered width, so its
/// placement reads the column from its own bounds.
struct LAAOwnerBubbleWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        guard let width = proposal.width, width.isFinite else { return child.sizeThatFits(proposal) }
        let size = child.sizeThatFits(Self.childProposal(width: width, height: proposal.height))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let offer = Self.childProposal(width: bounds.width, height: proposal.height)
        let size = child.sizeThatFits(offer)
        child.place(at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY), proposal: ProposedViewSize(size))
    }

    static func childProposal(width: CGFloat, height: CGFloat?) -> ProposedViewSize {
        ProposedViewSize(width: LAATranscriptMetrics.ownerBubbleMaxWidth(column: width), height: height)
    }
}

/// Who speaks a row of the transcript.
enum LAATranscriptActor: Equatable {
    case owner
    case staff
    case agent
    case thinking
    case toolWork
}

/// The speaker line above a turn: the 24 pt picture, the name in 13/500 and
/// the role as a muted 12 pt label (`Administration`, `Secretary`), and the
/// message's time. The owner's line trails, mirrored.
struct LAATranscriptSpeakerLine<Avatar: View>: View {
    let name: String
    var role: String? = nil
    var timestamp: String? = nil
    var trailing = false
    var nameIdentifier = "chat.sender.agent"
    @ViewBuilder let avatar: Avatar

    var body: some View {
        HStack(spacing: LAATranscriptMetrics.speakerSpacing) {
            if trailing {
                LAATranscriptTime(timestamp: timestamp)
                if let role { LAATranscriptRoleLabel(role: role) }
                nameText
                avatarView
            } else {
                avatarView
                nameText
                if let role { LAATranscriptRoleLabel(role: role) }
                LAATranscriptTime(timestamp: timestamp)
            }
        }
        .frame(minHeight: LAATranscriptMetrics.avatar)
    }

    private var avatarView: some View {
        avatar.frame(width: LAATranscriptMetrics.avatar, height: LAATranscriptMetrics.avatar)
            .accessibilityHidden(true)
    }

    private var nameText: some View {
        Text(verbatim: name)
            .font(.system(size: LAATranscriptMetrics.speakerNameSize, weight: .medium))
            .foregroundStyle(LAAColor.text)
            .lineLimit(1)
            .laaPhotoSupportingText()
            .accessibilityIdentifier(nameIdentifier)
    }
}

/// A role in the speaker line: muted `label` text, never a plate (C12).
struct LAATranscriptRoleLabel: View {
    let role: String
    @ScaledMetric(relativeTo: .caption) private var size = LAATranscriptMetrics.speakerRoleSize
    var body: some View {
        Text(verbatim: role)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(LAAColor.secondaryText)
            .lineLimit(1)
            .laaPhotoSupportingText()
    }
}

/// A message's time in the speaker line, 12 tabular muted.
struct LAATranscriptTime: View {
    let timestamp: String?
    var body: some View {
        if let timestamp, let label = MessageTimestampFormatter.displayString(for: timestamp) {
            Text(verbatim: label)
                .font(.system(size: LAATranscriptMetrics.speakerRoleSize, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(LAAColor.secondaryText)
                .laaPhotoSupportingText()
        }
    }
}

/// The owner's turn: the speaker line (picture, LAA, Administration) and,
/// 8 pt under it, the bubble the caller puts in `content` (it applies
/// `laaTranscriptOwnerBubble()` to what sits inside). `continues` drops the
/// line for the next message of the same run.
struct LAATranscriptOwnerTurn<Content: View>: View {
    var continues = false
    var timestamp: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .trailing, spacing: LAATranscriptMetrics.speakerToProse) {
            if !continues {
                LAATranscriptSpeakerLine(name: LAAOwnerIdentity.name, role: LAAOwnerIdentity.role,
                                         timestamp: timestamp, trailing: true, nameIdentifier: "chat.sender.owner.name") {
                    LAAOwnerAvatarView()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: LAAOwnerIdentity.spokenHeader))
                .accessibilityIdentifier("chat.sender.owner")
            }
            LAAOwnerBubbleWidth { content }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, continues ? 0 : LAATranscriptMetrics.turnGap - LAATranscriptMetrics.rowGap)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// An employee's or an agent's turn: the speaker line, then the prose flush
/// with the margin on the paper. No bubble.
struct LAATranscriptAgentTurn<Avatar: View, Content: View>: View {
    let name: String
    var continues = false
    var role: String? = nil
    var timestamp: String? = nil
    @ViewBuilder let avatar: Avatar
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LAATranscriptMetrics.speakerToProse) {
            if !continues {
                LAATranscriptSpeakerLine(name: name, role: role, timestamp: timestamp) { avatar }
            }
            content
                .frame(maxWidth: LAATranscriptMetrics.proseMeasure ?? .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, continues ? 0 : LAATranscriptMetrics.turnGap - LAATranscriptMetrics.rowGap)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The thinking row (HO-05): the particle orb and one muted line, no box, the
/// same in Chat and in Session. `isLive` animates the orb; a settled line
/// holds a still frame.
struct LAAThoughtLine: View {
    let text: String
    var isLive = true
    var state: LAAOrbState = .thinking
    /// Words arriving as they are thought: the line keeps its newest end and
    /// one identity, so a delta never restarts the fade.
    var streams = false

    var body: some View {
        HStack(spacing: LAATranscriptMetrics.speakerSpacing) {
            LAAOrbView(state: isLive ? state : .idle, diameter: LAATranscriptMetrics.thoughtOrb, isOnScreen: isLive)
                // Under the speaker's picture, where the reply will start.
                .frame(width: LAATranscriptMetrics.avatar, height: LAATranscriptMetrics.avatar)
            Text(verbatim: text)
                .id(streams ? "live" : text)
                .font(.system(size: LAATranscriptMetrics.thoughtTextSize))
                .foregroundStyle(LAAColor.secondaryText)
                .lineLimit(1)
                .truncationMode(streams ? .head : .tail)
                .contentTransition(streams ? .identity : .opacity)
            Spacer(minLength: 0)
        }
        .frame(minHeight: LAATranscriptMetrics.thoughtMinHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }
}

/// The owner's soft bubble: `wash`, radius 18, 12 × 16 inside, no outline
/// and no tail. The conversation's optional Liquid Glass (2026-11-16
/// exception, C3) now dresses only this bubble.
private struct LAATranscriptOwnerBubble: ViewModifier {
    @Environment(\.laaBubble) private var bubble
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: LAATranscriptMetrics.ownerBubbleRadius, style: .continuous)
        let padded = content
            .padding(.horizontal, LAATranscriptMetrics.ownerBubblePaddingH)
            .padding(.vertical, LAATranscriptMetrics.ownerBubblePaddingV)
            .foregroundStyle(LAAColor.text)
        if #available(iOS 26.0, *), bubble == .glass, !reduceTransparency {
            GlassEffectContainer {
                padded.glassEffect(LAABubbleGlass.glass(own: false, dark: colorScheme == .dark), in: shape)
            }
        } else {
            padded.background(LAAColor.subtleSurface, in: shape)
        }
    }
}

extension View {
    /// The owner's bubble around a message's content.
    func laaTranscriptOwnerBubble() -> some View { modifier(LAATranscriptOwnerBubble()) }
}
#endif
