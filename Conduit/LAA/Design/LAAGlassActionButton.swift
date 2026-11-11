#if LAA_BUILD
import SwiftUI

/// The round Liquid Glass button of a composer's bottom row: attach, stop and
/// Send. A 36 pt glass circle that answers a 44 pt touch, so the row stays
/// 36 pt tall while every button meets the touch target.
///
/// Its colour is fixed by its role, not by whether it can be pressed now
/// (owner, 2026-11-12: Send changed colour once text was typed; it keeps the
/// colour it had before). A button that cannot act is only disabled.
///
/// Display and action only, free of Work's and Chat's types:
///
///     LAAGlassActionButton(systemImage: "arrow.up", label: "送信", enabled: canSubmit,
///                          identifier: "work.composer.send", action: submit)
///     LAAGlassActionButton(systemImage: "stop.fill", label: "中断", role: .stop, action: stop)
///     LAAGlassActionButton(systemImage: "photo", label: "画像を添付", role: .neutral) { … }
struct LAAGlassActionButton: View {
    enum Role {
        /// Send and the like: the secondary ink on clear glass, as Send was
        /// before anything was typed.
        case send
        /// Attach and other plain actions: the text ink on clear glass.
        case neutral
        /// Ends the running turn: the end colour's square on a faint tint.
        case stop
    }

    let systemImage: String
    /// What VoiceOver reads.
    let label: String
    var role: Role = .send
    var enabled = true
    var identifier: String? = nil
    let action: () -> Void

    static let size: CGFloat = 36
    static let touch: CGFloat = 44

    init(systemImage: String, label: String, role: Role = .send, enabled: Bool = true,
         identifier: String? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.role = role
        self.enabled = enabled
        self.identifier = identifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            LAAGlassActionFace(systemImage: systemImage, role: role, enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(verbatim: label))
        .modifier(LAAOptionalIdentifier(identifier: identifier))
    }
}

/// The glass circle itself, for a control that is not a plain button (the
/// system photo picker wraps its own label).
struct LAAGlassActionFace: View {
    let systemImage: String
    var role: LAAGlassActionButton.Role = .neutral
    var enabled = true

    private var ink: Color {
        switch role {
        case .send: LAAColor.secondaryText
        case .neutral: enabled ? LAAColor.text : LAAColor.secondaryText
        case .stop: enabled ? LAAColor.end : LAAColor.secondaryText
        }
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: role == .stop ? 12 : 15, weight: .bold))
            .foregroundStyle(ink)
            .frame(width: LAAGlassActionButton.size, height: LAAGlassActionButton.size)
            .conduitGlassControl(cornerRadius: LAAGlassActionButton.size / 2,
                                 tint: role == .stop ? LAAColor.end.opacity(0.10) : .clear,
                                 interactive: enabled)
            // 36 pt to the eye, 44 pt to the finger.
            .contentShape(Circle().inset(by: -(LAAGlassActionButton.touch - LAAGlassActionButton.size) / 2))
    }
}

private struct LAAOptionalIdentifier: ViewModifier {
    let identifier: String?
    func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) } else { content }
    }
}
#endif
