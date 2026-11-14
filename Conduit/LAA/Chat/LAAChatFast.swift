#if LAA_BUILD
import SwiftUI

/// What the chat composer's Fast capsule shows and offers. The value is the
/// speed Hermes reported for the chat on screen (`fast` and `service_tier`),
/// never the profile's configured tier; a choice is written for this chat
/// only (session-scoped `/fast`).
enum LAAChatFastControl {
    struct Display: Equatable {
        let speed: ModelSpeed
        /// The speeds the menu lists. Fewer than two means a press toggles
        /// 通常 ⇄ Fast; empty means the value is fixed.
        let choices: [ModelSpeed]
        /// Why it cannot be changed now, or nil.
        let lock: String?

        var on: Bool { speed != .normal }
        /// A press flips it; otherwise it opens a menu (choices, or the reason).
        var toggles: Bool { lock == nil && choices.count < 3 }
    }

    /// Nil hides the capsule: Hermes has not reported this chat's speed, or
    /// the model has no Fast to turn on.
    static func display(speed: ModelSpeed?, capability: ModelSpeedCapability?, sessionID: String?,
                        connected: Bool, writable: Bool, writing: Bool) -> Display? {
        guard let speed else { return nil }
        if let capability, !capability.fast, !capability.ultrafast, speed == .normal { return nil }
        let ultrafast = capability?.ultrafast == true || speed == .ultrafast
        let lock: String? = {
            guard sessionID != nil else { return "会話を始めると変更できます。" }
            guard connected else { return "Hermesに接続していません。" }
            guard writable else { return "この会話ではFastを変更できません。" }
            return writing ? "変更中です。" : nil
        }()
        return Display(speed: speed, choices: ultrafast ? [.normal, .fast, .ultrafast] : [.normal, .fast], lock: lock)
    }

    static func name(_ speed: ModelSpeed) -> String {
        switch speed {
        case .normal: return "通常"
        case .fast: return "Fast"
        case .ultrafast: return "Ultrafast"
        }
    }

    /// The word on the capsule: 「Fast」 off or on, 「Ultrafast」 when it is.
    static func word(_ speed: ModelSpeed) -> String { speed == .ultrafast ? "Ultrafast" : "Fast" }

    /// The speed a press on a toggling capsule asks for.
    static func toggled(_ speed: ModelSpeed) -> ModelSpeed { speed == .normal ? .fast : .normal }

    /// The model's speed support from `model.options`, for the running model.
    static func capability(_ providers: [ProviderInfo], model: String?, provider: String?) -> ModelSpeedCapability? {
        guard let model, let provider, let row = providers.first(where: { $0.matches(provider) }) else { return nil }
        let wanted = model.lowercased()
        return row.speedCapabilities[model] ?? row.speedCapabilities.first { $0.key.lowercased() == wanted }?.value
    }
}

/// A chat whose model, effort and speed are not Hermes' to report or change:
/// the capsules show these values and their menus say why (owner, 2026-11-14:
/// Monet · Dots reads GPT 6 Astra · Ultra Code · Fast on and offers no choice;
/// owner, 2026-11-14 20:45).
struct LAAChatFixedRuntime: Equatable {
    let model: String
    let provider: String
    /// The name on the model capsule, whole (LAAModelCapsule.fullName).
    let name: String
    let effort: String
    let speed: ModelSpeed
    let reason: String

    static let dots = LAAChatFixedRuntime(model: "gpt-6-astra", provider: "openai-codex", name: "GPT 6 Astra", effort: "ultracode",
                                          speed: .fast, reason: "Monet（Dots）はモデルと推論を選べません。")

    static func of(profile: String) -> LAAChatFixedRuntime? {
        LAAStaff(profile: profile) == .monetDots ? dots : nil
    }

    var fast: LAAChatFastControl.Display { .init(speed: speed, choices: [], lock: reason) }
}

/// The Fast capsule's face, shared by Work's session row and Chat's composer:
/// the bolt and its word on the same 36 pt glass as the model and effort.
struct LAAFastCapsuleLabel: View {
    let on: Bool
    var word = "Fast"
    var changing = false
    var pressable = true

    var body: some View {
        HStack(spacing: LAASpacing.x1) {
            if changing { Text(verbatim: "変更中").font(.caption) }
            Image(systemName: on ? "bolt.fill" : "bolt")
                .font(.system(size: 13, weight: .semibold))
            Text(verbatim: word)
        }
        .laaTextStyle(.secondary)
        .foregroundStyle(on ? LAAColor.link : LAAColor.secondaryText)
        .padding(.horizontal, LAASpacing.x3).frame(minHeight: 36)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .conduitGlassControl(cornerRadius: 18, tint: pressable ? LAAColor.link.opacity(0.06) : .clear,
                             interactive: pressable)
    }
}

/// Chat's Fast capsule: a press toggles 通常 ⇄ Fast; with Ultrafast on offer
/// it opens the three speeds. When nothing can be chosen the menu still
/// opens and says why (owner, 2026-11-11).
struct LAAChatFastCapsule: View {
    let display: LAAChatFastControl.Display
    var changing = false
    let identifier: String
    let choose: (ModelSpeed) -> Void

    private var label: some View {
        LAAFastCapsuleLabel(on: display.on, word: LAAChatFastControl.word(display.speed),
                            changing: changing, pressable: display.lock == nil)
    }

    var body: some View {
        Group {
            if display.toggles {
                Button { choose(LAAChatFastControl.toggled(display.speed)) } label: { label }
                    .buttonStyle(.plain)
            } else {
                Menu {
                    if let lock = display.lock { LAAMenuReason(text: lock) }
                    Section {
                        ForEach(display.choices) { speed in
                            Button { choose(speed) } label: {
                                if speed == display.speed {
                                    Label { Text(verbatim: LAAChatFastControl.name(speed)) } icon: { Image(systemName: "checkmark") }
                                } else {
                                    Text(verbatim: LAAChatFastControl.name(speed))
                                }
                            }
                            .disabled(display.lock != nil || speed == display.speed)
                            .accessibilityIdentifier(identifier + "." + speed.rawValue)
                        }
                    }
                } label: { label }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
        .accessibilityLabel(Text(verbatim: "Fastモード"))
        .accessibilityValue(Text(verbatim: LAAChatFastControl.name(display.speed)))
        .accessibilityHint(Text(verbatim: display.lock ?? "この会話の応答速度を変更"))
        .accessibilityIdentifier(identifier)
    }
}
#endif
