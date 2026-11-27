#if LAA_BUILD

import Foundation
#if !os(watchOS)
import LAATokens
import SwiftUI
#endif

enum LAATab: String, CaseIterable, Identifiable {
    case chats
    case today
    case studio
    case work
    case brain
    case source
    case usage

    static let destinations: [LAATab] = [.chats, .work, .today, .brain, .studio]

    var id: String { rawValue }

    /// The tab's name, also its navigation title.
    var title: String { LAACopy.tabTitle(self) }

    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .today: return "calendar"
        case .studio: return "sparkles.rectangle.stack"
        case .work: return "list.bullet"
        case .brain: return "doc.text"
        case .source: return "photo.on.rectangle"
        case .usage: return "gauge.medium"
        }
    }

    #if !os(watchOS)
    /// The bottom bar's own artwork where it differs from `icon`: Doc keeps the page it had before the kit
    /// icons (SF Symbol `doc.text`, builds up to 2611260645), by the owner's choice (D-21, 2026-11-27:
    /// 「下部のタブバーのアイコンはDocのみもとにもどして」). The other tabs use the kit icons.
    var barArtwork: (regular: Image, selected: Image)? {
        self == .brain ? (Self.symbol("doc.text"), Self.symbol("doc.text.fill")) : nil
    }

    /// An SF Symbol without its spoken description: `Image(systemName:)` adds
    /// "Plain Text Document" beside the tab's own name for VoiceOver and UI tests.
    private static func symbol(_ name: String) -> Image {
        #if canImport(UIKit)
        if let image = UIImage(systemName: name) { return Image(uiImage: image) }
        #endif
        return Image(systemName: name)
    }

    var icon: LAAIcon {
        switch self {
        case .chats: .chat
        case .today: .calendar
        case .studio: .studio
        case .work: .work
        case .brain: .brain
        case .source: .image
        case .usage: .usage
        }
    }
    #endif

    /// The screen opens on this tab when launched with `-laa-tab <rawValue>`.
    /// DEBUG only, for manual simulator inspection of each tab.
    static var launched: LAATab? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-laa-tab"), index + 1 < arguments.count else {
            return nil
        }
        return LAATab(rawValue: arguments[index + 1])
        #else
        return nil
        #endif
    }
}

#endif
