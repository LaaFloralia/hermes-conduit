#if LAA_BUILD
import SwiftUI

/// The same control layer the new-session sheet shows, under the follow-up
/// field: model · effort and Fast on Liquid Glass. Only actions the Bridge and
/// its Paseo daemon actually advertise are interactive; the applied values come
/// from the daemon, never from the request that started the session.
struct LAAWorkSessionControls: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let session: LAAWorkSession
    let options: LAAWorkSessionOptions?
    @Binding var changing: Bool
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

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack(spacing: LAASpacing.x2) {
                modelPill
                fastPill(session.observedFast)
                Spacer(minLength: 0)
            }
            if let notice {
                Text(verbatim: notice).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
            }
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
            Text(verbatim: modelText)
                .fontWeight(.semibold).lineLimit(1)
            if interactive {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
            }
        }
        .laaTextStyle(.secondary).foregroundStyle(LAAColor.text)
        .padding(.horizontal, LAASpacing.x3).frame(minHeight: 36)
        .conduitGlassControl(cornerRadius: 18, interactive: interactive)
    }

    /// Always visible, as on the new-session sheet. The daemon does not always
    /// report this provider toggle; a failed observation also leaves the last
    /// value in hand, so the pill says 未確認 instead of presenting it as current.
    private func fastPill(_ on: Bool?) -> some View {
        let shown = observing ? on : nil
        let value: String
        if let shown { value = shown ? "オン" : "オフ" }
        else if let on, !observing { value = "最終確認: \(on ? "オン" : "オフ")" }
        else { value = "未確認" }
        return HStack(spacing: 4) {
            Image(systemName: shown == true ? "bolt.fill" : "bolt").font(.system(size: 13, weight: .semibold))
            Text(verbatim: shown == nil ? "Fast 未確認" : "Fast")
        }
        .laaTextStyle(.secondary)
        .foregroundStyle(shown == true ? LAAColor.link : LAAColor.secondaryText)
        .padding(.horizontal, LAASpacing.x3).frame(minHeight: 36)
        .lineLimit(1)
        .conduitGlassControl(cornerRadius: 18, interactive: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Fastモード"))
        .accessibilityValue(Text(verbatim: value))
        .accessibilityHint(Text(verbatim: observing ? "開始後は変更できません"
                                                    : "最後に確認した値です。現在値は未確認です。"))
        .accessibilityIdentifier("work.session.fast")
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
}
#endif
