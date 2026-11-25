import SwiftUI

/// One turn of a conversation. The owner's turn sits in a `wash` bubble; every other speaker writes on the paper
/// under a speaker row (there is no assistant bubble).
public struct LAATranscriptTurn: Identifiable, Equatable, Sendable {
    public enum Actor: Equatable, Sendable {
        case owner
        case speaker(name: String, role: String? = nil)
    }
    public let id: String
    public let actor: Actor
    public let text: String
    /// The reply is still arriving: show the orb line until text exists.
    public let isStreaming: Bool
    /// Optional live activity under a streaming reply (e.g. "ファイルを読んでいます").
    public let activity: String?

    public init(id: String, actor: Actor, text: String, isStreaming: Bool = false, activity: String? = nil) {
        self.id = id; self.actor = actor; self.text = text; self.isStreaming = isStreaming; self.activity = activity
    }
}

/// The conversation column. Turns 24 pt apart; on Mac the reading column is 680 pt (max 720), left-aligned.
/// Starts at the bottom and keeps following new text. `trailing` adds per-turn content (e.g. a subagent group).
public struct LAATranscript<Trailing: View>: View {
    let turns: [LAATranscriptTurn]
    let trailing: (LAATranscriptTurn) -> Trailing
    @Environment(\.laaPalette) private var palette

    public init(turns: [LAATranscriptTurn], @ViewBuilder trailing: @escaping (LAATranscriptTurn) -> Trailing) {
        self.turns = turns
        self.trailing = trailing
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LAAComponentToken.Transcript.turnGap) {
                ForEach(turns) { turn in
                    VStack(alignment: .leading, spacing: LAAComponentToken.Transcript.paragraphGap) {
                        LAATranscriptTurnView(turn: turn)
                        trailing(turn)
                    }
                    .id(turn.id)
                }
            }
            .frame(maxWidth: LAAPlatform.current == .mac ? LAAPlatform.current.canvas.readingMeasure : .infinity,
                   alignment: .leading)
            .padding(.horizontal, LAAPlatform.current == .mac ? LAAPlatform.current.canvas.margin : LAAPlatform.current.canvas.marginCompact)
            .padding(.vertical, LAASpace.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .background(palette.bg)
    }
}

public extension LAATranscript where Trailing == EmptyView {
    init(turns: [LAATranscriptTurn]) { self.init(turns: turns) { _ in EmptyView() } }
}

struct LAATranscriptTurnView: View {
    let turn: LAATranscriptTurn
    @Environment(\.laaPalette) private var palette

    var body: some View {
        switch turn.actor {
        case .owner:
            LAAOwnerBubble(text: turn.text)
        case .speaker(let name, let role):
            VStack(alignment: .leading, spacing: LAAComponentToken.Transcript.speakerGap) {
                LAASpeakerRow(name: name, role: role)
                if turn.text.isEmpty && turn.isStreaming {
                    LAAThinkingLine(label: turn.activity ?? "考えています")
                } else {
                    LAAMarkdownView(turn.text)
                    if turn.isStreaming, let activity = turn.activity { LAAThinkingLine(label: activity) }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

/// The owner's words: `wash`, radius 18, padding 12/16, at most 78 % of the column (Mac 560 pt), trailing.
public struct LAAOwnerBubble: View {
    let text: String
    @Environment(\.laaPalette) private var palette
    public init(text: String) { self.text = text }

    public var body: some View {
        let t = LAAComponentToken.Transcript.self
        let layout = LAATrailingFraction(fraction: t.bubbleMaxWidth,
                                         cap: LAAPlatform.current == .mac ? t.bubbleMaxWidthMac : .infinity)
        layout {
            let value = LAAMarkdownParser.inline(text)
            Text(value)
                .modifier(LAAReadingModifier(role: .body, strong: false, hasLinks: value.runs.contains { $0.link != nil }))
                .foregroundStyle(palette.text)
                .padding(.vertical, t.bubblePaddingV)
                .padding(.horizontal, t.bubblePaddingH)
                .background(RoundedRectangle(cornerRadius: t.bubbleRadius, style: .continuous).fill(palette.wash))
        }
    }
}

/// Speaker row: optional 24 pt mascot, name 13/500, role 12 muted.
public struct LAASpeakerRow: View {
    let name: String
    let role: String?
    let mascot: Image?
    @Environment(\.laaPalette) private var palette

    public init(name: String, role: String? = nil, mascot: Image? = nil) {
        self.name = name; self.role = role; self.mascot = mascot
    }

    public var body: some View {
        let t = LAAComponentToken.Transcript.self
        HStack(spacing: LAASpace.s8) {
            if let mascot {
                mascot.resizable().scaledToFill()
                    .frame(width: t.mascot, height: t.mascot)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }
            Text(name).laaFont(t.speakerName, weight: .medium).foregroundStyle(palette.text)
            if let role {
                Text(role).laaFont(t.speakerRole).foregroundStyle(palette.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The orb (16 pt, thinking) and a muted label while a reply is on its way.
public struct LAAThinkingLine: View {
    let label: String
    @Environment(\.laaPalette) private var palette
    public init(label: String) { self.label = label }

    public var body: some View {
        HStack(spacing: LAASpace.s8) {
            LAAParticleOrb(size: LAASpace.s16, state: .thinking)
            Text(label).laaOperating(.small).foregroundStyle(palette.textMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// Places one child at the trailing edge, at most `fraction` of the proposed width (and `cap`), hugging content.
struct LAATrailingFraction: Layout {
    let fraction: Double
    let cap: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width ?? 10_000
        let limit = min(width * fraction, cap)
        let size = child.sizeThatFits(ProposedViewSize(width: limit, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let limit = min(bounds.width * fraction, cap)
        let size = child.sizeThatFits(ProposedViewSize(width: limit, height: nil))
        child.place(at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height))
    }
}
