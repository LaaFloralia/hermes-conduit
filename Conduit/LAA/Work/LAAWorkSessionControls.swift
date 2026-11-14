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
    /// Which capsule says 変更中 while `changing`.
    @State private var changingWhat: Change = .effort
    private enum Change { case model, effort }

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
    /// A model the table does not list still shows its applied effort,
    /// checked and not offered, rather than an empty menu.
    private var choices: [String] {
        let listed = LAAWorkSessionStyle.effortChoices(session, options: options)
        return listed.isEmpty ? (currentEffort.map { [$0] } ?? []) : listed
    }
    private var models: [LAAWorkModelSelection.Model] { LAAWorkModelSelection.models(options?.switchingOptions).filter {
        session.capabilities?.providerSwitch == true || $0.provider == session.observed?.provider
    } }
    /// False when the last read could not reach Paseo. The value we hold is then
    /// the last confirmed one, not the current setting.
    private var observing: Bool { session.observation?.available != false }
    private var modelText: String? { applied.map { observing ? $0 : "最終確認 " + $0 } }
    private var stopped: Bool { ["stopped", "stop_unconfirmed"].contains(session.phase) }
    private var canChangeEffort: Bool {
        sharedLock == nil && session.capabilities?.effort == true && choices.count > 1
    }
    private var canChangeModel: Bool {
        sharedLock == nil && (session.capabilities?.model == true || session.capabilities?.providerSwitch == true) && models.count > 1
    }
    private var fast: LAAWorkFastControl.Display? {
        LAAWorkFastControl.display(observing: observing, observed: session.observedFast,
                                   capable: session.capabilities?.fast)
    }

    var body: some View {
        HStack(spacing: LAASpacing.x2) {
            if let modelText, let modelName, let currentEffort { pickers(modelText, name: modelName, effort: currentEffort) }
            if let fast { fastPill(fast) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.session.settings")
    }

    /// Why nothing in a menu can be chosen, in one line, so a tap always
    /// answers instead of doing nothing (owner, 2026-11-11).
    private var sharedLock: String? {
        if !observing { return "最後に確認した値です。現在値は未確認です。" }
        if stopped { return "停止したセッションは変更できません。" }
        if changing || session.modelSwitch != nil { return "モデルを引き継ぎ中です。" }
        if session.needsDecision { return "判断に回答してから変更できます。" }
        if ["running", "starting"].contains(session.phase) { return "実行が終わってから変更できます。" }
        return nil
    }
    private var modelLock: String? {
        if let sharedLock { return sharedLock }
        if session.capabilities?.model != true && session.capabilities?.providerSwitch != true { return "このセッションではモデルを変更できません。" }
        if models.count < 2 { return "切り替えられるモデルがありません。" }
        return nil
    }
    private var effortLock: String? {
        if let sharedLock { return sharedLock }
        if session.capabilities?.effort != true { return "このセッションでは推論を変更できません。" }
        if choices.count < 2 { return "このモデルで選べる推論はこれだけです。" }
        return nil
    }

    /// Model and effort, each its own capsule and menu (LAAModelEffortPickers,
    /// also in the new-session sheet, the task form and Chat). The model menu
    /// lists the session provider's models under the request → running line;
    /// the effort menu, the current model's efforts. What cannot be changed
    /// stays listed and disabled, with the reason at the top.
    private func pickers(_ modelText: String, name: String, effort: String) -> some View {
        LAAModelEffortPickers(
            model: currentModel, provider: session.observed?.provider, effort: effort, name: name,
            current: observing, attention: mismatch != nil, changingModel: (changing && changingWhat == .model) || session.modelSwitch != nil,
            changingEffort: changing && changingWhat != .model, identifier: "work.session",
            modelValueSuffix: mismatch.map { "、依頼 " + $0.requested },
            modelHint: modelLock ?? "モデルを変更", effortHint: effortLock ?? "推論の強さを変更"
        ) {
            if let mismatch {
                // Why the face says another model than the one asked for.
                Section {
                    Button {} label: {
                        Text(verbatim: "依頼 \(mismatch.requested) → 実行 \(mismatch.running)")
                        if let seen = mismatch.seen { Text(verbatim: seen) }
                    }.disabled(true)
                }
            }
            if let modelLock { LAAMenuReason(text: modelLock) }
            ForEach(LAAWorkModelSelection.providers(models), id: \.name) { group in
                Section(group.name) {
                    ForEach(group.models) { choice in
                        let selected = choice.model == currentModel && choice.provider == session.observed?.provider
                        Button { changeModel(choice) } label: {
                            if selected {
                                Label { Text(verbatim: choice.label) } icon: { Image(systemName: "checkmark") }
                            } else {
                                LAAModelMenu.Name(label: choice.label, model: choice.model)
                            }
                        }
                        .disabled(!canChangeModel || selected || targetProfile(choice) == nil)
                        .accessibilityIdentifier("work.session.model.\(choice.provider).\(choice.model)")
                    }
                }
            }
        } effortMenu: {
            if let effortLock { LAAMenuReason(text: effortLock) }
            Section {
                ForEach(choices, id: \.self) { choice in
                    LAAEffortMenu.Row(effort: choice, selected: choice == currentEffort) { change(choice) }
                        .disabled(!canChangeEffort || choice == currentEffort || !offered(choice))
                }
            }
        }
    }

    /// A value Paseo can apply to this model. The daemon's current value is
    /// listed even when it is not (effortChoices), but never offered.
    private func offered(_ effort: String) -> Bool {
        LAAWorkSessionStyle.offeredEfforts(provider: session.observed?.provider, model: currentModel, options: options).contains(effort)
    }

    private func targetProfile(_ model: LAAWorkModelSelection.Model) -> LAAWorkSessionOptions.Profile? {
        let offered = model.profiles.filter {
            (model.provider == session.observed?.provider && session.capabilities?.model == true)
                || (model.provider != session.observed?.provider && session.capabilities?.providerSwitch == true
                    && ["high", "xhigh", "max", "ultra"].contains($0.effort))
        }
        return offered.first { $0.effort == currentEffort } ?? offered.first { $0.effort == "high" } ?? offered.first
    }

    private func changeModel(_ model: LAAWorkModelSelection.Model) {
        guard canChangeModel, let target = targetProfile(model) else { return }
        changingWhat = .model
        changing = true
        notice = nil
        Task { @MainActor in
            defer { changing = false }
            struct Change: Encodable { let provider: String; let model: String; let effort: String }
            do {
                let _: LAAWorkSession = try await LAAWorkHTTP.write(
                    bridge, path: "/v1/sessions/\(session.id)",
                    body: JSONEncoder().encode(Change(provider: target.provider, model: target.model, effort: target.effort)),
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
        LAAFastCapsuleLabel(on: display.value, changing: changingFast, pressable: pressable)
    }

    private func change(_ effort: String) {
        guard !changing, effort != currentEffort else { return }
        changingWhat = .effort
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
