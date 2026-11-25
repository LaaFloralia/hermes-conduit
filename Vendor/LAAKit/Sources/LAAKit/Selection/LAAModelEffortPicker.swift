#if !os(watchOS)
import LAATokens
import SwiftUI

/// A model option, supplied in the order the caller wants it shown.
public struct LAAPickerModel: Identifiable, Sendable, Equatable {
    /// The adopted finish, not a rank inferred from the name or identifier.
    public enum Tier: CaseIterable, Sendable {
        /// Purple Mythos marble.
        case mythos
        /// Blue Astra marble.
        case astra
        /// Teal Neon marble.
        case neon
        /// Neutral stone for strong effort; a plain model capsule.
        case stone
        /// A plain model capsule with the default neutral strong-effort finish.
        case plain
    }

    /// Stable caller-owned selection identifier.
    public let id: String
    /// The complete name as shown, including the maker where applicable.
    public let displayName: String
    /// The caller’s choice of finish.
    public let tier: Tier
    /// Whether this option can be selected.
    public let isEnabled: Bool

    /// Creates an option without interpreting its name or identifier.
    public init(id: String, displayName: String, tier: Tier = .plain, isEnabled: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.tier = tier
        self.isEnabled = isEnabled
    }
}

/// An effort option with a caller-supplied label and optional menu detail.
public struct LAAPickerEffort: Identifiable, Sendable, Equatable {
    /// Stable selection identifier; `xhigh`, `max` and `ultracode` carry the adopted finishes.
    public let id: String
    /// The label to show in both the menu and capsule.
    public let displayName: String
    /// Optional explanatory copy shown only in the menu.
    public let detail: String?
    /// Whether this option can be selected.
    public let isEnabled: Bool

    /// Creates an effort option without applying or carrying effort across models.
    public init(id: String, displayName: String, detail: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.isEnabled = isEnabled
    }
}

/// Two wrapping glass menus that display applied values and report selections to the caller.
public struct LAAModelEffortPicker: View {
    /// Caller-supplied display state; the picker does not manage application requests.
    public struct Status: Sendable {
        /// Whether the supplied values are current rather than last confirmed.
        public let isCurrent: Bool
        /// Whether the applied model differs from the requested one.
        public let showsModelAttention: Bool
        /// Whether a caller-owned model change is applying.
        public let isChangingModel: Bool
        /// Whether a caller-owned effort change is applying.
        public let isChangingEffort: Bool
        /// Whether the parent allows animation (false for an offscreen retained view).
        public let isActive: Bool
        /// Additional context to include in the model’s spoken value.
        public let modelValueSuffix: String?

        /// Creates the presentation state; applied IDs stay separate from pending state.
        public init(isCurrent: Bool = true, showsModelAttention: Bool = false,
                    isChangingModel: Bool = false, isChangingEffort: Bool = false,
                    isActive: Bool = true, modelValueSuffix: String? = nil) {
            self.isCurrent = isCurrent
            self.showsModelAttention = showsModelAttention
            self.isChangingModel = isChangingModel
            self.isChangingEffort = isChangingEffort
            self.isActive = isActive
            self.modelValueSuffix = modelValueSuffix
        }
    }

    private let models: [LAAPickerModel]
    private let efforts: [LAAPickerEffort]
    private let selectedModelID: String?
    private let selectedEffortID: String?
    private let identifier: String
    private let status: Status
    private let modelMark: (@MainActor (LAAPickerModel) -> AnyView)?
    private let onSelectModel: @MainActor (String) -> Void
    private let onSelectEffort: @MainActor (String) -> Void

    /// Pass applied IDs and two callbacks; optionally supply the host app’s original provider mark.
    public init(models: [LAAPickerModel], efforts: [LAAPickerEffort],
                selectedModelID: String?, selectedEffortID: String?,
                identifier: String = "laa.picker", status: Status = .init(),
                modelMark: (@MainActor (LAAPickerModel) -> AnyView)? = nil,
                onSelectModel: @escaping @MainActor (String) -> Void,
                onSelectEffort: @escaping @MainActor (String) -> Void) {
        self.models = models
        self.efforts = efforts
        self.selectedModelID = selectedModelID
        self.selectedEffortID = selectedEffortID
        self.identifier = identifier
        self.status = status
        self.modelMark = modelMark
        self.onSelectModel = onSelectModel
        self.onSelectEffort = onSelectEffort
    }

    /// Renders independent model and effort menus without truncating the model name.
    public var body: some View {
        let model = models.first { $0.id == selectedModelID }
        let effort = efforts.first { $0.id == selectedEffortID }
        let tier = model?.tier ?? .plain
        let modelStyle = LAAMarbleStyle(tier: tier, step: status.isCurrent ? tier.modelStep : .plain)
        let effortStyle = LAAMarbleStyle(tier: tier, step: status.isCurrent ? .effort(effort?.id) : .plain)
        LAAWrapRow {
            Menu {
                if models.isEmpty { unavailable }
                ForEach(models) { option in
                    Toggle(isOn: applied(option.id, selectedModelID, onSelectModel)) {
                        Text(verbatim: option.displayName)
                    }
                    .disabled(!option.isEnabled)
                    .accessibilityIdentifier(identifier + ".model." + option.id)
                }
            } label: {
                LAAPickerCapsule(label: model?.displayName, id: model?.id, style: modelStyle, isModel: true,
                                 current: status.isCurrent, changing: status.isChangingModel, active: status.isActive,
                                 attention: status.showsModelAttention, mark: model.flatMap { modelMark?($0) })
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "モデル"))
            .accessibilityValue(Text(verbatim: label(model?.displayName) + (status.modelValueSuffix ?? "")))
            .accessibilityHint(Text(verbatim: "モデルを変更"))
            .accessibilityIdentifier(identifier + ".model")

            Menu {
                if efforts.isEmpty { unavailable }
                ForEach(efforts) { option in
                    Toggle(isOn: applied(option.id, selectedEffortID, onSelectEffort)) {
                        Text(verbatim: option.displayName)
                        if let detail = option.detail { Text(verbatim: detail) }
                    }
                    .disabled(!option.isEnabled)
                    .accessibilityIdentifier(identifier + ".effort." + option.id)
                }
            } label: {
                LAAPickerCapsule(label: effort?.displayName, id: effort?.id, style: effortStyle, isModel: false,
                                 current: status.isCurrent, changing: status.isChangingEffort, active: status.isActive)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: "推論"))
            .accessibilityValue(Text(verbatim: label(effort?.displayName)))
            .accessibilityHint(Text(verbatim: "推論の強さを変更"))
            .accessibilityIdentifier(identifier + ".effort")
        }
    }

    private func label(_ value: String?) -> String {
        status.isCurrent ? (value ?? "不明") : "最終確認 " + (value ?? "不明")
    }

    private var unavailable: some View {
        Button {} label: { Text(verbatim: "変更できません") }.disabled(true)
    }

    private func applied(_ id: String, _ selection: String?, _ choose: @escaping @MainActor (String) -> Void) -> Binding<Bool> {
        Binding(get: { id == selection }, set: { on in if on && id != selection { choose(id) } })
    }
}

private struct LAAPickerCapsule: View {
    let label: String?
    let id: String?
    let style: LAAMarbleStyle
    let isModel: Bool
    let current: Bool
    let changing: Bool
    let active: Bool
    var attention = false
    var mark: AnyView?

    @Environment(\.laaPalette) private var palette
    @LAAReduceMotion private var reduceMotion
    @LAAReduceTransparency private var reduceTransparency
    @ScaledMetric(relativeTo: .footnote) private var fontSize = LAACanvas.iphone.small
    @State private var ceremony = LAACeremonyTrigger()

    private let markSize = LAAAppSelection.heightPt - 2 * (LAASpace.s8 - LAASpace.s4 / 4)

    var body: some View {
        HStack(spacing: LAASpace.s8 - LAASpace.s4 / 2) {
            if isModel { modelMark }
            if changing {
                Text(verbatim: "変更中").font(.caption).fixedSize()
            }
            if attention {
                Image(systemName: "triangle.fill")
                    .font(.system(size: LAASpace.s8 - LAASpace.s4 / 4, weight: .bold))
                    .foregroundStyle(palette.second)
                    .accessibilityHidden(true)
            }
            Text(verbatim: (isModel && !current ? "最終確認 " : "") + (label ?? "不明"))
                .fontWeight(isModel ? .semibold : .medium)
                .foregroundStyle(label != nil && (isModel || current) ? palette.text : palette.textMuted)
                .multilineTextAlignment(.leading)
                .lineLimit(isModel ? nil : 1)
                .fixedSize(horizontal: !isModel, vertical: true)
                .layoutPriority(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: LAAIconSize.default / 2, weight: .semibold))
                .foregroundStyle(palette.textMuted)
                .accessibilityHidden(true)
        }
        .font(.system(size: fontSize))
        .foregroundStyle(palette.text)
        .padding(.leading, isModel ? (LAAAppSelection.heightPt - markSize) / 2 : LAASpace.s12)
        .padding(.trailing, LAASpace.s12)
        .frame(minHeight: LAAAppSelection.heightPt)
        .contentShape(RoundedRectangle(cornerRadius: LAAAppSelection.cornerRadiusPt, style: .continuous))
        .modifier(LAAPickerGlass(style: style, seed: LAAMarble.seed(id), active: active,
                                 start: ceremony.start))
        .onChange(of: LAACeremonyTrigger.Input(id: id, changing: changing)) { old, new in
            ceremony.update(from: old, to: new, now: .now,
                            enabled: current && active && !style.isPlain && !reduceMotion && !reduceTransparency)
        }
    }

    private var modelMark: some View {
        Group {
            if let mark { mark }
            else {
                Image(systemName: "sparkle")
                    .font(.system(size: LAAIconSize.default * 0.6, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // laa-design:allow icon-tile Neutral model face, not an icon button.
                    .background(palette.wash, in: Circle())
            }
        }
        .frame(width: markSize, height: markSize)
        .accessibilityHidden(true)
    }
}
#endif
