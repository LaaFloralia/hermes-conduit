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
    private var choices: [String] { LAAWorkSessionStyle.effortChoices(session, options: options) }
    /// False when the last read could not reach Paseo. The value we hold is then
    /// the last confirmed one, not the current setting.
    private var observing: Bool { session.observation?.available != false }
    private var modelText: String {
        guard let applied else { return "モデル未確認" }
        return observing ? applied : "最終確認 \(applied)"
    }
    private var canChangeEffort: Bool {
        observing && session.capabilities?.effort == true && !changing && choices.count > 1
    }
    private var fast: LAAWorkFastControl.Display? {
        LAAWorkFastControl.display(observing: observing, observed: session.observedFast,
                                   capable: session.capabilities?.fast)
    }

    var body: some View {
        HStack(spacing: LAASpacing.x2) {
            modelPill
            if let fast { fastPill(fast) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.session.settings")
    }

    @ViewBuilder private var modelPill: some View {
        if canChangeEffort {
            Menu {
                ForEach(choices, id: \.self) { effort in
                    Button { change(effort) } label: {
                        if effort == currentEffort {
                            Label { Text(verbatim: LAAWorkSessionStyle.effort(effort) ?? effort) }
                                icon: { Image(systemName: "checkmark") }
                        } else {
                            Text(verbatim: LAAWorkSessionStyle.effort(effort) ?? effort)
                        }
                    }
                }
            } label: {
                pill(interactive: true)
            }
            .accessibilityLabel(Text(verbatim: "モデルと推論"))
            .accessibilityValue(Text(verbatim: modelText))
            .accessibilityHint(Text(verbatim: "推論の強さを変更"))
            .accessibilityIdentifier("work.session.effort")
        } else {
            pill(interactive: false)
                .accessibilityLabel(Text(verbatim: "モデルと推論"))
                .accessibilityValue(Text(verbatim: modelText))
                .accessibilityHint(Text(verbatim: observing ? "開始後は変更できません"
                                                            : "最後に確認した値です。現在値は未確認です。"))
                .accessibilityIdentifier("work.session.model")
        }
    }

    private func pill(interactive: Bool) -> some View {
        HStack(spacing: LAASpacing.x1) {
            if changing { ProgressView().controlSize(.small) }
            // The row keeps every control on one line: only the model name
            // gives way when the screen is narrow.
            Text(verbatim: modelText)
                .fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
            if interactive {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
            }
        }
        .laaTextStyle(.secondary).foregroundStyle(LAAColor.text)
        .padding(.horizontal, LAASpacing.x3).frame(minHeight: 36)
        .conduitGlassControl(cornerRadius: 18, interactive: interactive)
        .layoutPriority(-1)
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
            if changingFast { ProgressView().controlSize(.small) }
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
