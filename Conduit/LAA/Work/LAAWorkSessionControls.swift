#if LAA_BUILD
import SwiftUI

/// Whether the Fast pill appears and whether it may be pressed. The daemon's
/// `observedFast` says the model has a Fast value at all; the Bridge's
/// `capabilities.fast` says this session may change it.
enum LAAWorkFastControl {
    struct Display: Equatable {
        /// The value in hand: the live one while observing, else the last one.
        let value: Bool
        /// False when the daemon could not be reached, so the value is history.
        let current: Bool
        let canToggle: Bool
    }

    static func display(observing: Bool, observed: Bool?, capable: Bool?) -> Display? {
        guard let observed else { return nil }
        guard observing else { return Display(value: observed, current: false, canToggle: false) }
        return Display(value: observed, current: true, canToggle: capable == true)
    }

    static func valueText(_ display: Display) -> String {
        let state = display.value ? "オン" : "オフ"
        return display.current ? state : "最終確認: " + state
    }

    static func hint(_ display: Display) -> String {
        if display.current { return display.canToggle ? "Fastの切り替え" : "開始後は変更できません" }
        return "最後に確認した値です。現在値は未確認です。"
    }
}

/// The session's model · effort and Fast pills, on the same Liquid Glass as the
/// new-session sheet. They sit in the composer's one row; only actions the
/// Bridge and its Paseo daemon advertise are interactive, and the applied
/// values come from the daemon, never from the request that started the
/// session.
struct LAAWorkSessionControls: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let session: LAAWorkSession
    let options: LAAWorkSessionOptions?
    @Binding var changing: Bool
    @Binding var changingFast: Bool
    @Binding var notice: String?
    let refresh: () async -> Void

    private var applied: String? { LAAWorkSessionStyle.appliedModel(session, options: options) }
    private var currentEffort: String? { session.observed?.effort }
    private var currentModel: String? { session.observed?.model }
    /// The model half of the pill. The effort is its own half beside it, so
    /// it never truncates away with a long model name.
    private var modelName: String? {
        guard applied != nil else { return nil }
        return LAAWorkSessionStyle.modelName(currentModel, provider: session.observed?.provider, options: options)
            ?? LAAWorkSessionStyle.providerName(session.observed?.provider, model: currentModel)
    }
    private var mismatch: LAAWorkSessionStyle.Mismatch? { LAAWorkSessionStyle.mismatch(session, options: options) }
    private var choices: [String] { LAAWorkSessionStyle.effortChoices(session, options: options) }
    private var models: [LAAWorkSessionStyle.ModelChoice] { LAAWorkSessionStyle.modelChoices(session, options: options) }
    /// False when the last read could not reach Paseo. The value we hold is then
    /// the last confirmed one, not the current setting.
    private var observing: Bool { session.observation?.available != false }
    private var modelText: String? { applied.map { observing ? $0 : "最終確認 " + $0 } }
    private var stopped: Bool { ["stopped", "stop_unconfirmed"].contains(session.phase) }
    private var canChangeEffort: Bool {
        observing && !stopped && session.capabilities?.effort == true && !changing && choices.count > 1
    }
    private var canChangeModel: Bool {
        observing && !stopped && session.capabilities?.model == true && !changing && models.count > 1
    }
    private var fast: LAAWorkFastControl.Display? {
        LAAWorkFastControl.display(observing: observing, observed: session.observedFast,
                                   capable: session.capabilities?.fast)
    }

    var body: some View {
        HStack(spacing: LAASpacing.x2) {
            if let modelText, let modelName, let currentEffort { modelPill(modelText, name: modelName, effort: currentEffort) }
            if let fast { fastPill(fast) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.session.settings")
    }

    /// Why nothing in the menu can be chosen, in one line, so a tap always
    /// answers instead of doing nothing (owner, 2026-11-11).
    private var lockedReason: String? {
        if !observing { return "最後に確認した値です。現在値は未確認です。" }
        if stopped { return "停止したセッションは変更できません。" }
        if changing { return "変更中です。" }
        if !canChangeModel && !canChangeEffort { return "このセッションでは変更できません。" }
        return nil
    }

    /// The pill always opens its menu (owner, 2026-11-11: a tap on a running
    /// session's model did nothing): the models of the session's provider, then
    /// the efforts of the current model. What cannot be changed stays listed
    /// and disabled, with the reason at the top.
    private func modelPill(_ modelText: String, name: String, effort: String) -> some View {
        Menu {
            if let mismatch {
                // Why the face says another model than the one asked for.
                Section {
                    Button {} label: {
                        Text(verbatim: "依頼 \(mismatch.requested) → 実行 \(mismatch.running)")
                        if let seen = mismatch.seen { Text(verbatim: seen) }
                    }.disabled(true)
                }
            }
            if let lockedReason {
                Section { Button {} label: { Text(verbatim: lockedReason) }.disabled(true) }
            }
            if !models.isEmpty {
                Section {
                    ForEach(models, id: \.self) { choice in
                        Button { changeModel(choice.model) } label: {
                            if choice.model == currentModel {
                                Label { Text(verbatim: choice.label) } icon: { Image(systemName: "checkmark") }
                            } else {
                                Text(verbatim: choice.label)
                            }
                        }
                        .disabled(!canChangeModel || choice.model == currentModel)
                        .accessibilityIdentifier("work.session.model.\(choice.model)")
                    }
                } header: { Text(verbatim: "モデル") }
            }
            if !choices.isEmpty {
                Section {
                    ForEach(choices, id: \.self) { choice in
                        LAAEffortMenu.Row(effort: choice, selected: choice == currentEffort) { change(choice) }
                            .disabled(!canChangeEffort || choice == currentEffort || !offered(choice))
                    }
                } header: { Text(verbatim: "推論") }
            }
        } label: {
            pill(name: name, effort: effort)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "モデルと推論"))
        .accessibilityValue(Text(verbatim: mismatch.map { modelText + "、依頼 " + $0.requested } ?? modelText))
        .accessibilityHint(Text(verbatim: lockedReason ?? "モデルと推論の強さを変更"))
        .accessibilityIdentifier("work.session.effort")
    }

    /// A value the HQ table offers for this model. The daemon's current value
    /// is listed even when it is not (effortChoices), but never offered.
    private func offered(_ effort: String) -> Bool {
        options?.profiles.contains { $0.provider == session.observed?.provider && $0.model == currentModel && $0.effort == effort } == true
    }

    /// The shared chip (LAAModelEffortChip, also in Chat's composer), with the
    /// name from the model table. It always opens the menu, so it always
    /// carries the chevron, even when nothing in it can be chosen.
    private func pill(name: String, effort: String) -> some View {
        LAAModelEffortChip(model: currentModel, provider: session.observed?.provider, effort: effort,
                           name: name, current: observing, interactive: true,
                           attention: mismatch != nil, changing: changing)
            .layoutPriority(-1)
    }

    private func changeModel(_ model: String) {
        guard !changing, model != currentModel else { return }
        changing = true
        notice = nil
        Task { @MainActor in
            defer { changing = false }
            struct Change: Encodable { let model: String }
            do {
                let _: LAAWorkSession = try await LAAWorkHTTP.write(
                    bridge, path: "/v1/sessions/\(session.id)",
                    body: JSONEncoder().encode(Change(model: model)),
                    key: LAABridgeIdempotencyKey(), method: "PATCH")
                await refresh()
            } catch let error as LAABridgeHTTPError {
                notice = LAAWorkHTTP.message(error)
                await refresh()
            } catch {
                notice = "モデルを変更できませんでした。"
            }
        }
    }

    /// The word is always "Fast"; the value and its freshness live in the
    /// accessibility value and hint, so the row stays 36pt tall.
    @ViewBuilder private func fastPill(_ display: LAAWorkFastControl.Display) -> some View {
        let pressable = display.canToggle && !changingFast
        if pressable {
            Button { changeFast(!display.value) } label: { fastLabel(display, pressable: true) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Fastモード"))
                .accessibilityValue(Text(verbatim: LAAWorkFastControl.valueText(display)))
                .accessibilityHint(Text(verbatim: LAAWorkFastControl.hint(display)))
                .accessibilityIdentifier("work.session.fast")
        } else {
            fastLabel(display, pressable: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Fastモード"))
                .accessibilityValue(Text(verbatim: LAAWorkFastControl.valueText(display)))
                .accessibilityHint(Text(verbatim: LAAWorkFastControl.hint(display)))
                .accessibilityIdentifier("work.session.fast")
        }
    }

    private func fastLabel(_ display: LAAWorkFastControl.Display, pressable: Bool) -> some View {
        HStack(spacing: LAASpacing.x1) {
            if changingFast { Text(verbatim: "変更中").font(.caption) }
            Image(systemName: display.value ? "bolt.fill" : "bolt")
                .font(.system(size: 13, weight: .semibold))
            Text(verbatim: "Fast")
        }
        .laaTextStyle(.secondary)
        .foregroundStyle(display.value ? LAAColor.link : LAAColor.secondaryText)
        .padding(.horizontal, LAASpacing.x3).frame(minHeight: 36)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .conduitGlassControl(cornerRadius: 18, tint: pressable ? LAAColor.link.opacity(0.06) : .clear,
                             interactive: pressable)
    }

    private func change(_ effort: String) {
        guard !changing, effort != currentEffort else { return }
        changing = true
        notice = nil
        Task { @MainActor in
            defer { changing = false }
            struct Change: Encodable { let effort: String }
            do {
                let _: LAAWorkSession = try await LAAWorkHTTP.write(
                    bridge, path: "/v1/sessions/\(session.id)",
                    body: JSONEncoder().encode(Change(effort: effort)),
                    key: LAABridgeIdempotencyKey(), method: "PATCH")
                await refresh()
            } catch let error as LAABridgeHTTPError {
                notice = LAAWorkHTTP.message(error)
                await refresh()
            } catch {
                notice = "推論設定を変更できませんでした。"
            }
        }
    }

    /// The same flow as an effort change: the request carries only the toggle,
    /// the answer is read again, and a refusal is explained in Japanese.
    private func changeFast(_ on: Bool) {
        guard !changingFast else { return }
        changingFast = true
        notice = nil
        Task { @MainActor in
            defer { changingFast = false }
            struct Change: Encodable { let fast: Bool }
            do {
                let _: LAAWorkSession = try await LAAWorkHTTP.write(
                    bridge, path: "/v1/sessions/\(session.id)",
                    body: JSONEncoder().encode(Change(fast: on)),
                    key: LAABridgeIdempotencyKey(), method: "PATCH")
                await refresh()
            } catch let error as LAABridgeHTTPError {
                notice = LAAWorkHTTP.message(error)
                await refresh()
            } catch {
                notice = "Fastを変更できませんでした。"
            }
        }
    }
}
#endif
