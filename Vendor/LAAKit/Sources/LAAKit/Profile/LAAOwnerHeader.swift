import SwiftUI

/// The speaker's name style shared with Hortensia's conversation headers.
public struct LAASenderName: View {
    let text: String
    @Environment(\.laaPalette) private var palette
    @ScaledMetric(relativeTo: .footnote) private var size = LAAPlatform.current.canvas.small

    public init(text: String) { self.text = text }

    public var body: some View {
        Text(verbatim: text)
            .font(.system(size: size))
            .foregroundStyle(palette.textMuted)
            .lineLimit(1)
    }
}

/// The owner's Administration role, on a square-cornered plate (D-30).
public struct LAAAdministrationBadge: View {
    static let role = "Administration"
    @Environment(\.laaPalette) private var palette
    @ScaledMetric(relativeTo: .caption) private var size = LAAPlatform.current.canvas.label

    public init() {}

    public var body: some View {
        Text(verbatim: Self.role)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(palette.textMuted)
            .lineLimit(1)
            .padding(.horizontal, LAASpace.s8)
            .padding(.vertical, LAASpace.s4)
            .background(palette.wash, in: RoundedRectangle(cornerRadius: LAARadius.small))
    }
}

/// The owner's name and Administration badge, read as one phrase by VoiceOver.
public struct LAAOwnerHeader: View {
    let name: String
    let badgeFirst: Bool

    public init(name: String = LAAOwnerProfileStore.defaultDisplayName, badgeFirst: Bool = false) {
        self.name = name
        self.badgeFirst = badgeFirst
    }

    public var body: some View {
        HStack(spacing: LAASpace.s8) {
            if badgeFirst { LAAAdministrationBadge().layoutPriority(1) }
            LAASenderName(text: name)
            if !badgeFirst { LAAAdministrationBadge().layoutPriority(1) }
        }
        .accessibilityRepresentation { Text(verbatim: "\(name)、\(LAAAdministrationBadge.role)") }
        .accessibilityIdentifier("chat.sender.owner")
    }
}
