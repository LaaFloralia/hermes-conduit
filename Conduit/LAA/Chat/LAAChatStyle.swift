#if LAA_BUILD
import SwiftUI

extension LAACopy {
    static let chatToday = "今日"
    static let chatYesterday = "昨日"
    static let chatAttach = "添付"
    static let chatSend = "送信"
    static let chatExpandEditor = "入力欄を拡大"
    static let chatCopy = "コピー"
    static let chatCopied = "コピーしました"
    static let chatCode = "コード"
    static let chatStop = "応答を中断"
    static let chatSteer = "メッセージで指示"
    static let chatInterrupt = "中断して指示"
    static let chatQueue = "送信待ちに追加"
    static let chatComposerUnavailable = "入力できません"
    static let chatFileUnavailable = "このファイルを開けません"
    static let chatCall = "電話"
    static let chatGroupCallUnavailable = "このグループは通話に対応していません"
    static let chatBackground = "背景"
    static let chatGroupSettings = "グループの設定"
    static let chatPaper = "紙"
    static let chatTealNight = "青緑"
    static let chatInk = "墨"
    static let chatDevicePhoto = "写真"
    static let chatSelected = "選択中"
    static let chatDone = "完了"
    static let chatPhotoAdjustments = "写真の調整"
    static let chatPhotoDim = "暗さ"
    static let chatPhotoBlur = "ぼかし"
    static let chatLoadingPhoto = "写真を読み込み中"
    static let chatFixturePhoto = "試験用の写真"
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
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日（E）"
        return formatter.string(from: date)
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
        VStack(spacing: 14) {
            if let date, LAAChatDay.startsSection(date, after: previous) {
                LAAChatDateSeparator(date: date).padding(.top, 24)
            }
            content
        }
    }
}

private struct LAAChatColumn: ViewModifier {
    let alignment: Alignment
    func body(content: Content) -> some View {
        content
            .containerRelativeFrame(.horizontal) { width, _ in min(720, width - 40) }
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

/// The composer's +, field and send in Liquid Glass, as in Messages:
/// regular glass, never clear, so a transcript scrolling under the field
/// stays frosted behind the draft. On a photo the glass takes the photo
/// toolbar's 38% dark underlay and light ink (LAAComposerPhotoInk).
/// Reduce Transparency and iOS 17–25 get the opaque reading surface with
/// a hairline; Increase Contrast firms the border (the separator has its
/// own high-contrast value).
private struct LAAComposerGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    /// The send colour once there is something to send.
    let fill: Color?
    let interactive: Bool
    @Environment(\.laaBackgroundKind) private var kind
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            let glass = Glass.regular.tint(fill)
            content
                .background { if kind == .photo { shape.fill(.black.opacity(0.38)) } }
                .glassEffect(interactive ? glass.interactive() : glass, in: shape)
                .overlay { if contrast == .increased { shape.strokeBorder(LAAColor.separator, lineWidth: 1) } }
        } else {
            content
                .background(fill ?? LAAColor.surface, in: shape)
                .overlay { shape.strokeBorder(LAAColor.separator, lineWidth: 1) }
        }
    }
}

/// Light ink for the composer on a photo, where the darkened photo sits
/// behind it in either appearance. Controls on the opaque fallback keep
/// the app's appearance; `bare` ones sit on the photo itself.
private struct LAAComposerPhotoInk: ViewModifier {
    let bare: Bool
    @Environment(\.laaBackgroundKind) private var kind
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if kind == .photo, bare || Self.glassAvailable && !reduceTransparency {
            content.environment(\.colorScheme, .dark)
        } else {
            content
        }
    }

    private static var glassAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

/// One glass group for the composer, kept apart at rest: neighbouring
/// controls must not melt into each other.
private struct LAAComposerGlassGroup: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}

enum LAAComposerShape {
    /// Half the 44pt controls, so a single line is a capsule like the
    /// buttons beside it and taller drafts keep the same corners.
    static var field: RoundedRectangle {
        RoundedRectangle(cornerRadius: LAASpacing.minimumTouchTarget / 2, style: .continuous)
    }
}

extension View {
    func laaChatDaySection(date: Date?, previous: Date?) -> some View {
        modifier(LAAChatDaySection(date: date, previous: previous))
    }
    func laaChatColumn(_ alignment: Alignment) -> some View { modifier(LAAChatColumn(alignment: alignment)) }
    func laaComposerGlass<S: InsettableShape>(in shape: S, fill: Color? = nil, interactive: Bool = true) -> some View {
        modifier(LAAComposerGlass(shape: shape, fill: fill, interactive: interactive))
    }
    func laaComposerPhotoInk(bare: Bool = false) -> some View { modifier(LAAComposerPhotoInk(bare: bare)) }
    func laaComposerGlassGroup() -> some View { modifier(LAAComposerGlassGroup()) }
}
#endif
