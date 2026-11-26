#if LAA_BUILD && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import SwiftUI
import WidgetKit
#if LAA_WIDGET_TEST
@testable import Conduit

private final class LAAStaffCallTestResources {}
#endif

/// An in-app employee call on the Lock Screen and in the Dynamic Island
/// (HO-15): the employee's mascot and name, what the call is doing and how
/// long it has run. Same dark glass and type as the turn card
/// (HermesTurnLiveActivity.swift, LAAStaffActivityStyle); the mascot stands without a disc. On an
/// Apple Watch the system shows the compact pair in the Smart Stack.
struct LAAStaffCallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LAAStaffCallAttributes.self) { context in
            LAAStaffCallLockScreen(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .widgetURL(context.attributes.link)
                .activityBackgroundTint(LAAStaffActivityStyle.glass)
                .activitySystemActionForegroundColor(LAAStaffActivityStyle.gold)
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LAAStaffCallIsland.expandedLeading(attributes)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LAAStaffCallIsland.expandedTrailing(state)
                }
                DynamicIslandExpandedRegion(.center) {
                    LAAStaffCallIsland.expandedCenter(attributes, state)
                }
            } compactLeading: {
                LAAStaffCallIsland.compactLeading(attributes, state)
            } compactTrailing: {
                LAAStaffCallIsland.compactTrailing(state)
            } minimal: {
                LAAStaffCallIsland.minimal(attributes, state)
            }
            .widgetURL(attributes.link)
            .keylineTint(LAAStaffCallIsland.tint(state.callPhase))
        }
    }
}

/// The turn card's dark glass and colors (HermesTurnStyle's LAA values),
/// here so this file builds alone in the unit tests' snapshot target.
enum LAAStaffActivityStyle {
    static let gold = LAAColorValues.color(LAAColorValues.linkDark)
    static let attention = LAAColorValues.color(LAAColorValues.attentionDark)
    static let glass = LAAColorValues.color(LAAColorValues.surfaceDark).opacity(0.9)
}

/// The island's pieces, one function each, so a snapshot test can lay them
/// out the way the system does.
enum LAAStaffCallIsland {
    static func tint(_ phase: LAAStaffCallPhase) -> Color {
        switch phase {
        case .muted: LAAStaffActivityStyle.attention
        case .ended: .secondary
        default: LAAStaffActivityStyle.gold
        }
    }

    static func expandedLeading(_ attributes: LAAStaffCallAttributes) -> some View {
        LAAWidgetStaffAvatar(profile: attributes.profile, size: 44, fallbackSymbol: "phone.fill")
            .padding(.leading, 2)
    }

    static func expandedCenter(_ attributes: LAAStaffCallAttributes, _ state: LAAStaffCallAttributes.ContentState) -> some View {
        LAAStaffCallHeadline(attributes: attributes, state: state)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.colorScheme, .dark)
    }

    static func expandedTrailing(_ state: LAAStaffCallAttributes.ContentState) -> some View {
        LAAStaffCallElapsed(state: state)
            .font(.title3.monospacedDigit().weight(.semibold))
            .foregroundStyle(state.callPhase.isFinished ? Color.primary : LAAStaffActivityStyle.gold)
            .frame(maxWidth: 76, alignment: .trailing)
            .padding(.trailing, 2)
    }

    static func compactLeading(_ attributes: LAAStaffCallAttributes, _ state: LAAStaffCallAttributes.ContentState) -> some View {
        LAAWidgetStaffAvatar(profile: attributes.profile, size: 24, fallbackSymbol: "phone.fill")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(attributes.name) \(LAACopy.staffCallState(state.callPhase))"))
    }

    @ViewBuilder
    static func compactTrailing(_ state: LAAStaffCallAttributes.ContentState) -> some View {
        if state.connectedAt == nil || state.callPhase == .muted || state.callPhase.isFinished {
            Image(systemName: state.callPhase.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint(state.callPhase))
                .accessibilityHidden(true)
        } else {
            LAAStaffCallElapsed(state: state)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(LAAStaffActivityStyle.gold)
                .frame(maxWidth: 48)
        }
    }

    static func minimal(_ attributes: LAAStaffCallAttributes, _ state: LAAStaffCallAttributes.ContentState) -> some View {
        LAAWidgetStaffAvatar(profile: attributes.profile, size: 22, fallbackSymbol: "phone.fill")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(attributes.name) \(LAACopy.staffCallState(state.callPhase))"))
    }
}

struct LAAStaffCallLockScreen: View {
    let attributes: LAAStaffCallAttributes
    let state: LAAStaffCallAttributes.ContentState
    var isStale = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            LAAWidgetStaffAvatar(profile: attributes.profile, size: 48, fallbackSymbol: "phone.fill")
            LAAStaffCallHeadline(attributes: attributes, state: state)
            Spacer(minLength: 0)
            LAAStaffCallElapsed(state: state)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(state.callPhase.isFinished ? Color.primary : LAAStaffActivityStyle.gold)
                .frame(maxWidth: 88, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .opacity(isStale && !state.callPhase.isFinished ? 0.6 : 1)
    }
}

/// The name on a quiet line, the call's state under it with its symbol.
private struct LAAStaffCallHeadline: View {
    let attributes: LAAStaffCallAttributes
    let state: LAAStaffCallAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: attributes.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Label {
                Text(verbatim: LAACopy.staffCallState(state.callPhase))
            } icon: {
                Image(systemName: state.callPhase.symbol)
                    .foregroundStyle(LAAStaffCallIsland.tint(state.callPhase))
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
        }
    }
}

/// The call's time since it connected; nothing while it connects, the
/// final time once it ended.
private struct LAAStaffCallElapsed: View {
    let state: LAAStaffCallAttributes.ContentState

    var body: some View {
        if let start = state.connectedDate {
            if let end = state.endDate, end > start {
                Text(timerInterval: start...end, pauseTime: end, countsDown: false)
                    .multilineTextAlignment(.trailing)
            } else if !state.callPhase.isFinished {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

/// An employee's bundled still (LAAWidgetStaffArt), standing without a disc
/// or ring like everywhere in the app. A profile without one shows the
/// fallback symbol instead.
struct LAAWidgetStaffAvatar: View {
    let profile: String?
    let size: CGFloat
    var fallbackSymbol: String = "sparkles"

    var body: some View {
        if let name = LAAWidgetStaffArt.imageName(profile: profile) {
            #if LAA_WIDGET_TEST
            let image = Image(name, bundle: Bundle(for: LAAStaffCallTestResources.self))
            #else
            let image = Image(name)
            #endif
            image
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(LAAStaffActivityStyle.gold)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
#endif
