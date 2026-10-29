#if LAA_BUILD

import Foundation

enum LAATab: String, CaseIterable, Identifiable {
    case chats
    case work
    case brain
    case source
    case usage

    static let destinations: [LAATab] = [.chats, .work, .brain, .source, .usage]

    var id: String { rawValue }

    /// The tab's name, also its navigation title.
    var title: String { LAACopy.tabTitle(self) }

    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .work: return "checklist"
        case .brain: return "doc.text"
        case .source: return "photo.on.rectangle"
        case .usage: return "gauge.medium"
        }
    }

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
