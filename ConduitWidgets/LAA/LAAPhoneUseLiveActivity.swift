#if LAA_BUILD && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// An agent's request to operate the iPhone while it is in use, in the
/// Dynamic Island and on the Lock Screen: who asks and why, with Allow and
/// Don't Allow; once allowed, "operating" with Stop until the agent ends.
/// Same dark glass, disc and type as the turn activity
/// (HermesTurnLiveActivity.swift).
struct LAAPhoneUseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LAAPhoneUseAttributes.self) { context in
            LAAPhoneUseLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(HermesTurnStyle.glass)
                .activitySystemActionForegroundColor(HermesTurnStyle.gold)
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = LAAPhoneUseView.effective(context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LAAPhoneUseDisc(phase: state.usePhase, size: 40)
                        .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LAAPhoneUseClock(attributes: attributes, state: state)
                        .font(.headline.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 52, maxWidth: 76, alignment: .trailing)
                        .padding(.trailing, 2)
                }
                DynamicIslandExpandedRegion(.center) {
                    LAAPhoneUseHeadline(attributes: attributes, state: state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.colorScheme, .dark)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LAAPhoneUseButtons(attributes: attributes, phase: state.usePhase)
                        .padding(.horizontal, 2)
                        .padding(.top, 4)
                        .environment(\.colorScheme, .dark)
                }
            } compactLeading: {
                LAAPhoneUseIcon(phase: state.usePhase)
                    .font(.footnote.weight(.semibold))
                    .accessibilityLabel(Text(verbatim: LAAPhoneUseView.status(state.usePhase)))
            } compactTrailing: {
                LAAPhoneUseCompactTrailing(attributes: attributes, state: state)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: 52)
            } minimal: {
                LAAPhoneUseIcon(phase: state.usePhase)
                    .font(.footnote.weight(.semibold))
                    .accessibilityLabel(Text(verbatim: LAAPhoneUseView.status(state.usePhase)))
            }
            .keylineTint(LAAPhoneUseView.tint(state.usePhase))
        }
    }
}

enum LAAPhoneUseView {
    /// A question nobody answered goes stale at its answer time: it reads
    /// as expired even before the Bridge's end push arrives.
    static func effective(_ state: LAAPhoneUseAttributes.ContentState, isStale: Bool) -> LAAPhoneUseAttributes.ContentState {
        guard isStale, state.usePhase == .ask else { return state }
        return .init(phase: LAAPhoneUsePhase.expired.rawValue, since: nil, endedAt: nil)
    }

    static func status(_ phase: LAAPhoneUsePhase) -> String {
        switch phase {
        case .ask: LAACopy.phoneUseAsk
        case .operating: LAACopy.phoneUseOperating
        default: LAACopy.phoneUseFinished(phase)
        }
    }

    static func tint(_ phase: LAAPhoneUsePhase) -> Color {
        switch phase {
        case .ask: HermesTurnStyle.attention
        case .operating: HermesTurnStyle.gold
        default: .secondary
        }
    }

    static func symbol(_ phase: LAAPhoneUsePhase) -> String {
        switch phase {
        case .ask: "hand.raised.fill"
        case .operating: "iphone.gen3.radiowaves.left.and.right"
        case .denied, .stopped: "xmark"
        case .expired: "clock"
        case .ended: "checkmark"
        }
    }
}

private struct LAAPhoneUseLockScreenView: View {
    let attributes: LAAPhoneUseAttributes
    let state: LAAPhoneUseAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let state = LAAPhoneUseView.effective(state, isStale: isStale)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                LAAPhoneUseDisc(phase: state.usePhase, size: 40)
                LAAPhoneUseHeadline(attributes: attributes, state: state)
                Spacer(minLength: 0)
                LAAPhoneUseClock(attributes: attributes, state: state)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: 88, alignment: .trailing)
            }
            LAAPhoneUseButtons(attributes: attributes, phase: state.usePhase)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RadialGradient(colors: [HermesTurnStyle.gold.opacity(0.34), .clear],
                               center: UnitPoint(x: 0.08, y: 0.35), startRadius: 0,
                               endRadius: proxy.size.width * 0.62)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Who asks, on a quiet line; the question or status under it; the purpose.
private struct LAAPhoneUseHeadline: View {
    let attributes: LAAPhoneUseAttributes
    let state: LAAPhoneUseAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: attributes.who)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(verbatim: LAAPhoneUseView.status(state.usePhase))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(verbatim: attributes.purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The time left to answer while asking, the time operated while allowed.
private struct LAAPhoneUseClock: View {
    let attributes: LAAPhoneUseAttributes
    let state: LAAPhoneUseAttributes.ContentState

    var body: some View {
        switch state.usePhase {
        case .ask where attributes.answerDate > .now:
            Text(timerInterval: Date.now...attributes.answerDate, countsDown: true)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(HermesTurnStyle.attention)
        case .operating:
            Text(timerInterval: Date(timeIntervalSince1970: state.since ?? Date.now.timeIntervalSince1970)...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(HermesTurnStyle.gold)
        default:
            EmptyView()
        }
    }
}

private struct LAAPhoneUseCompactTrailing: View {
    let attributes: LAAPhoneUseAttributes
    let state: LAAPhoneUseAttributes.ContentState

    var body: some View {
        if state.usePhase == .operating {
            Text(verbatim: LAACopy.phoneUseOperatingShort)
                .foregroundStyle(HermesTurnStyle.gold)
        } else {
            LAAPhoneUseClock(attributes: attributes, state: state)
        }
    }
}

/// Allow / Don't Allow while asking, Stop while operating, none once ended.
private struct LAAPhoneUseButtons: View {
    let attributes: LAAPhoneUseAttributes
    let phase: LAAPhoneUsePhase

    var body: some View {
        switch phase {
        case .ask:
            HStack(spacing: 10) {
                button(LAACopy.phoneUseDeny, .deny, prominent: false)
                button(LAACopy.phoneUseAllow, .allow, prominent: true)
            }
        case .operating:
            button(LAACopy.phoneUseStop, .stop, prominent: false)
        default:
            EmptyView()
        }
    }

    private func button(_ title: String, _ answer: LAAPhoneUseAnswer, prominent: Bool) -> some View {
        Button(intent: LAAPhoneUseAnswerIntent(requestID: attributes.requestID, answer: answer)) {
            Text(verbatim: title)
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? Color.black.opacity(0.85) : Color.primary)
        .background(prominent ? AnyShapeStyle(HermesTurnStyle.gold) : AnyShapeStyle(Color.white.opacity(0.14)), in: Capsule())
        .accessibilityIdentifier("laa.phoneUse.\(answer.rawValue)")
    }
}

private struct LAAPhoneUseDisc: View {
    let phase: LAAPhoneUsePhase
    let size: CGFloat

    var body: some View {
        LAAPhoneUseIcon(phase: phase)
            .font(.system(size: size * 0.45, weight: .semibold))
            .frame(width: size, height: size)
            .background(LAAPhoneUseView.tint(phase).opacity(0.18), in: Circle())
    }
}

private struct LAAPhoneUseIcon: View {
    let phase: LAAPhoneUsePhase

    var body: some View {
        Image(systemName: LAAPhoneUseView.symbol(phase))
            .foregroundStyle(LAAPhoneUseView.tint(phase))
            .accessibilityHidden(true)
    }
}
#endif
