//
//  ReadableContentWidth.swift
//  Conduit
//
//  Conduit's screens were drawn for a phone. On a wide window (an iPad, a
//  landscape iPhone) a chat's lines, Settings' cards and a call's captions
//  would otherwise run the whole width of the window.
//

import SwiftUI

extension View {
    /// Keeps the content to `maxWidth`, centered, on a wider window. The
    /// content fills the space it's offered, so it suits a screen's whole
    /// content rather than a view with a size of its own. The
    /// margins go into the safe area rather than a frame: a backdrop that
    /// ignores the safe area still fills the window, and a scroll view still
    /// scrolls from its margins with its content inset. Nothing changes on a
    /// window narrower than `maxWidth`.
    func readableContentWidth(_ maxWidth: CGFloat) -> some View {
        modifier(ReadableContentWidth(maxWidth: { _ in maxWidth }))
    }

    /// A chat's column: `ReadableWidth.chat(available:)` wide, its text a
    /// size or more larger as the column grows (`ReadableWidth.chatTextSteps`),
    /// so a maximized window shows bigger text rather than longer lines.
    func readableChatColumn() -> some View {
        modifier(ReadableContentWidth(maxWidth: ReadableWidth.chat(available:), scalesChatText: true))
    }
}

/// Readable widths for the screens that cap theirs.
enum ReadableWidth {
    /// A chat's transcript and composer: the narrowest its column gets on a
    /// wide window. A wider window widens it (`chat(available:)`).
    static let chat: CGFloat = 760
    /// The widest a chat's column gets, however wide the window.
    static let chatMax: CGFloat = 1040
    /// The share of the chat's width its column takes between those two.
    static let chatShare: CGFloat = 0.72
    /// Settings' pages.
    static let settings: CGFloat = 720
    /// A Chats or Bots list shown on its own on a wide window, the list
    /// beside the chat hidden (`V2ChatListPreference`).
    static let list: CGFloat = 720
    /// A voice call's captions and controls.
    static let call: CGFloat = 640

    /// A chat's column for `available` points of width: the phone's
    /// 760 pt column on an iPad beside the list, growing with a maximized
    /// Mac or iPad window up to `chatMax`, so the text doesn't sit in a
    /// narrow strip in the middle of it.
    static func chat(available: CGFloat) -> CGFloat {
        min(chatMax, max(chat, (available * chatShare).rounded(.down)))
    }

    /// How many text sizes a chat's column of `column` points steps up
    /// from the system's: one for each size whose body text still fits
    /// as many words to a line as the 760 pt column holds (body at the
    /// default size is 17, 19, 21 and 23 pt). A phone, and an iPad
    /// beside the list, keep the system's size; a maximized window's
    /// 1040 pt column steps up three.
    static func chatTextSteps(column: CGFloat) -> Int {
        let growth = column / chat
        return chatTextGrowth.filter { growth >= $0 }.count
    }

    /// The body text growth each step brings at the default size
    /// (19, 21 and 23 pt over 17).
    static let chatTextGrowth: [CGFloat] = [19.0 / 17, 21.0 / 17, 23.0 / 17]

    /// The margin on each side that keeps `available` points of width to
    /// `maxWidth`.
    static func margin(available: CGFloat, maxWidth: CGFloat) -> CGFloat {
        max(0, ((available - maxWidth) / 2).rounded(.down))
    }
}

private struct ReadableContentWidth: ViewModifier {
    let maxWidth: (CGFloat) -> CGFloat
    var scalesChatText = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        // A reader rather than a measured state, so the first layout is
        // already at its width: a chat restoring its scroll position must
        // not lay its rows out twice.
        GeometryReader { proxy in
            let column = maxWidth(proxy.size.width)
            let steps = scalesChatText ? textSteps(column: column) : 0
            content
                .safeAreaPadding(.horizontal, ReadableWidth.margin(available: proxy.size.width, maxWidth: column))
                // Centered for content narrower than the window too; the
                // reader alone would put it at the leading edge.
                .frame(width: proxy.size.width, height: proxy.size.height)
                // The column's own text (step rows, cards, the composer)
                // through Dynamic Type; transcript text, which resolves
                // UIKit fonts, through the steps (ChatTextAppearance).
                .dynamicTypeSize(Self.boosted(dynamicTypeSize, by: steps))
                .environment(\.chatWidthTextSteps, steps)
        }
    }

    /// The steps the column can take: none past the largest standard size,
    /// so an accessibility size, already larger, stays as the user set it.
    private func textSteps(column: CGFloat) -> Int {
        let sizes = Self.standardSizes
        guard let index = sizes.firstIndex(of: dynamicTypeSize) else { return 0 }
        return min(ReadableWidth.chatTextSteps(column: column), sizes.count - 1 - index)
    }

    private static var standardSizes: [DynamicTypeSize] { ChatTypography.standardDynamicTypeSizes }

    private static func boosted(_ size: DynamicTypeSize, by steps: Int) -> DynamicTypeSize {
        guard steps > 0, let index = standardSizes.firstIndex(of: size) else { return size }
        return standardSizes[min(standardSizes.count - 1, index + steps)]
    }
}
