import SwiftUI

/// What the assistant is doing right now, shown in the strip above the composer.
public struct LAAWorkingState: Equatable, Sendable {
    public let label: String
    /// Elapsed time as the caller formats it (e.g. "0:42").
    public let elapsed: String?
    public let orb: LAAParticleOrb.State
    /// Running subagents; the strip shows the count and opens the list.
    public let agents: Int

    public init(label: String, elapsed: String? = nil, orb: LAAParticleOrb.State = .thinking, agents: Int = 0) {
        self.label = label; self.elapsed = elapsed; self.orb = orb; self.agents = agents
    }
}

/// The working strip: 36 pt (Mac 28 pt) glass capsule with the 16 pt orb, a 13/500 label and the subagent count.
/// The hit area stays 44 pt. Place it inside `LAAInputCluster` so it merges with the composer.
public struct LAAWorkingStrip: View {
    let state: LAAWorkingState
    let onAgents: () -> Void
    @Environment(\.laaPalette) private var palette

    public init(_ state: LAAWorkingState, onAgents: @escaping () -> Void) {
        self.state = state; self.onAgents = onAgents
    }

    public var body: some View {
        let size = LAAPlatform.current == .mac ? LAAComponentToken.WorkingStrip.mac : LAAComponentToken.WorkingStrip.iphone
        let extra = max(0, size.hitArea - size.height) / 2
        Button(action: onAgents) {
            HStack(spacing: LAASpace.s8) {
                LAAParticleOrb(size: size.orb, state: state.orb)
                Text(state.label)
                    .laaFont(size.label, weight: .medium)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                if let elapsed = state.elapsed {
                    Text(elapsed)
                        .laaFont(size.label, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(palette.text)
                }
                if state.agents > 0 {
                    Rectangle().fill(palette.rule).frame(width: LAAStroke.rule, height: size.label + LAASpace.s4)
                    Text("子 \(state.agents)")
                        .laaFont(size.label, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(palette.textMuted)
                }
            }
            .padding(.horizontal, size.paddingH)
            .frame(minHeight: size.height)
            .laaGlassCapsule()
            .padding(.vertical, extra)
            .contentShape(Rectangle())
            .padding(.vertical, -extra)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.agents > 0 ? "\(state.label)、子の作業 \(state.agents)件" : state.label)
    }
}

/// The input cluster: one glass group (spacing 12) holding the working strip, the jump-to-latest button and the
/// composer. The composer is opaque-edged glass; nothing inside it carries its own glass.
public struct LAAInputCluster<Composer: View>: View {
    let working: LAAWorkingState?
    let showsJump: Bool
    let onJump: () -> Void
    let onAgents: () -> Void
    let composer: Composer
    @Environment(\.laaPalette) private var palette

    public init(working: LAAWorkingState?, showsJump: Bool, onJump: @escaping () -> Void,
                onAgents: @escaping () -> Void, @ViewBuilder composer: () -> Composer) {
        self.working = working; self.showsJump = showsJump; self.onJump = onJump; self.onAgents = onAgents
        self.composer = composer()
    }

    public var body: some View {
        let mac = LAAPlatform.current == .mac
        let size = mac ? LAAComponentToken.WorkingStrip.mac : LAAComponentToken.WorkingStrip.iphone
        LAAGlassCluster(spacing: size.mergeSpacing) {
            VStack(spacing: size.gapAboveComposer) {
                if working != nil || showsJump {
                    HStack(spacing: size.mergeSpacing) {
                        if let working { LAAWorkingStrip(working, onAgents: onAgents) }
                        Spacer(minLength: 0)
                        if showsJump {
                            Button(action: onJump) {
                                LAAIconImage(.back, size: size.jumpIcon)
                                    .rotationEffect(.degrees(-90))
                                    .foregroundStyle(palette.accent)
                                    .frame(width: size.jump, height: size.jump)
                                    .laaGlass(in: Circle())
                                    .frame(minWidth: size.hitArea, minHeight: size.hitArea)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("最新へ移動")
                        }
                    }
                    .transition(.opacity)
                }
                composer
                    .padding(.horizontal, LAASpace.s16)
                    .padding(.vertical, LAASpace.s8)
                    .frame(minHeight: size.hitArea)
                    .laaGlass(in: RoundedRectangle(cornerRadius: LAARadius.tabSelection, style: .continuous),
                              interactive: false)
            }
            .padding(.horizontal, mac ? LAASpace.s16 : LAAPlatform.current.canvas.marginCompact)
            .padding(.bottom, LAASpace.s8)
        }
    }
}
