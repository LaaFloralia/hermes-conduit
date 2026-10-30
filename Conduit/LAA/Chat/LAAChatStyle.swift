#if LAA_BUILD
import SwiftUI

extension LAACopy {
    static let chatToday = "TODAY"
    static let chatYesterday = "YESTERDAY"
    static let chatAttach = "Attach"
    static let chatSend = "Send"
    static let chatExpandEditor = "Expand editor"
    static let chatCopy = "Copy"
    static let chatCopied = "Copied"
    static let chatCode = "Code"
    static let chatStop = "Stop response"
    static let chatSteer = "Steer with message"
    static let chatInterrupt = "Interrupt and correct response"
    static let chatQueue = "Queue message"
    static let chatComposerUnavailable = "Composer unavailable"
    static let chatFileUnavailable = "This group cannot open this file here."
    static let chatCall = "Call"
    static let chatGroupCallUnavailable = "Group calls are unavailable on this connection."
    static let chatBackground = "Background"
    static let chatGroupSettings = "Group settings"
    static let chatPaper = "Paper"
    static let chatTealNight = "Teal night"
    static let chatInk = "Ink"
    static let chatDevicePhoto = "Device photo"
    static let chatSelected = "Selected"
    static let chatDone = "Done"
    static let chatPhotoAdjustments = "Photo adjustments"
    static let chatPhotoDim = "Dim"
    static let chatPhotoBlur = "Blur"
    static let chatLoadingPhoto = "Loading photo"
    static let chatFixturePhoto = "Test photo"
}

private struct LAAChatDesignKey: EnvironmentKey {
    static let defaultValue = false
}

// Shared Markdown appears on paper as well as in chat cards.
private struct LAARichContentStyleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var laaChatDesign: Bool {
        get { self[LAAChatDesignKey.self] }
        set { self[LAAChatDesignKey.self] = newValue }
    }
    var laaRichContentStyle: Bool {
        get { self[LAARichContentStyleKey.self] }
        set { self[LAARichContentStyleKey.self] = newValue }
    }
}

enum LAAChatDay {
    static func previousDate(before order: Int, in visible: [ChatMessageScrollTarget]) -> Date? {
        var lower = 0
        var upper = visible.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if visible[middle].order < order { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return nil }
        return MessageTimestampFormatter.date(from: visible[lower - 1].message.timestamp)
    }

    static func startsSection(_ date: Date?, after previous: Date?, calendar: Calendar = .current) -> Bool {
        guard let date else { return false }
        guard let previous else { return true }
        return !calendar.isDate(date, inSameDayAs: previous)
    }

    static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return LAACopy.chatToday }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return LAACopy.chatYesterday }
        return date.formatted(.dateTime.month(.abbreviated).day().year().locale(Locale(identifier: "en_US"))).uppercased()
    }
}

enum LAALinkDecoration {
    /// Decorations stay out of copied text; member mentions are not external links.
    static func addingIndicators(to text: NSAttributedString) -> NSAttributedString {
        guard text.length > 0 else { return text }
        var ranges: [NSRange] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let url = (value as? URL) ?? (value as? String).flatMap { URL(string: $0) }
            guard let url, GroupRoomMentions.kind(ofLink: url) == nil, range.length > 0 else { return }
            ranges.append(range)
        }
        guard !ranges.isEmpty else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        for range in ranges.reversed() {
            var attributes = text.attributes(at: NSMaxRange(range) - 1, effectiveRange: nil)
            attributes[MarkdownProseRun.copiesAs] = ""
            attributes[.underlineStyle] = 0
            result.insert(NSAttributedString(string: " ↗", attributes: attributes), at: NSMaxRange(range))
        }
        return result
    }
}

struct LAAChatDateSeparator: View {
    let date: Date
    var body: some View {
        Text(verbatim: LAAChatDay.label(date))
            .laaTextStyle(.section)
            .fontWeight(.semibold)
            .foregroundStyle(LAAColor.secondaryText)
            .laaPhotoSupportingText()
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("chat.date.separator")
    }
}

private struct LAAChatDaySection: ViewModifier {
    let date: Date?
    let previous: Date?
    func body(content: Content) -> some View {
        VStack(spacing: LAASpacing.x2) {
            if let date, LAAChatDay.startsSection(date, after: previous) {
                LAAChatDateSeparator(date: date)
            }
            content
        }
    }
}

private struct LAAChatColumn: ViewModifier {
    let alignment: Alignment
    func body(content: Content) -> some View {
        content
            .containerRelativeFrame(.horizontal) { width, _ in width * 0.85 }
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

private struct LAAChatInputSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(LAAColor.text)
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.bubble, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LAARadius.bubble, style: .continuous)
                    .strokeBorder(LAAColor.separator, lineWidth: 1)
            }
    }
}

extension View {
    func laaChatDaySection(date: Date?, previous: Date?) -> some View {
        modifier(LAAChatDaySection(date: date, previous: previous))
    }
    func laaChatColumn(_ alignment: Alignment) -> some View { modifier(LAAChatColumn(alignment: alignment)) }
    func laaChatInputSurface() -> some View { modifier(LAAChatInputSurface()) }
}
#endif
