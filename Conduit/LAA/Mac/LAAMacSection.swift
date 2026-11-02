#if LAA_BUILD && targetEnvironment(macCatalyst)
import Combine
import Foundation
import SwiftUI

/// The Mac sidebar's sections, in the order the sidebar and ⌘1–⌘7 show them.
/// Each is one of the phone's tabs; Drive is the Assets tab's own entry, which
/// the phone reaches inside Studio.
enum LAAMacSection: String, CaseIterable, Identifiable {
    case chats
    case work
    case today
    case brain
    case studio
    case drive
    case usage

    var id: String { rawValue }

    var tab: LAATab {
        switch self {
        case .chats: return .chats
        case .work: return .work
        case .today: return .today
        case .brain: return .brain
        case .studio: return .studio
        case .drive: return .source
        case .usage: return .usage
        }
    }

    /// The section a widget link or a daily request asks for, or nil for a
    /// host this shell doesn't know.
    init?(linkHost: String) {
        switch linkHost {
        case "work": self = .work
        case "today": self = .today
        case "brain": self = .brain
        case "assets": self = .drive
        default: return nil
        }
    }

    var title: String { LAACopy.macSectionTitle(self) }

    var symbol: String {
        switch self {
        case .drive: return "folder"
        default: return tab.symbol
        }
    }

    /// ⌘1 is the first section, ⌘7 the last.
    var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    #if DEBUG
    /// `-laa-mac-section usage` opens that section at launch, so the
    /// screenshot script doesn't have to drive the sidebar. A release build
    /// has no such argument.
    static var launched: LAAMacSection? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-laa-mac-section"),
              index + 1 < arguments.count else { return nil }
        return LAAMacSection(rawValue: arguments[index + 1])
    }
    #endif

    var shortcutKey: KeyEquivalent {
        switch shortcutNumber {
        case 1: return "1"
        case 2: return "2"
        case 3: return "3"
        case 4: return "4"
        case 5: return "5"
        case 6: return "6"
        default: return "7"
        }
    }
}

/// What the menu bar asks the window to do. The window owns its selection and
/// its split view; commands only leave a request here, which the shell
/// consumes, so the menu and the window never hold two copies of the state.
@MainActor
final class LAAMacCommandsModel: ObservableObject {
    static let shared = LAAMacCommandsModel()

    /// A section the Go menu asked for, cleared once the shell shows it.
    @Published var pendingSection: LAAMacSection?
    /// Counters: each request bumps one, and the shell acts on the change.
    @Published var toggleSidebar = 0
    @Published var openSettings = 0
    @Published var focusSearch = 0
    @Published var reload = 0
    @Published var newChat = 0
    @Published var closeConversation = 0
}

extension LAACopy {
    static func macSectionTitle(_ section: LAAMacSection) -> String {
        switch section {
        case .drive: return "Drive"
        default: return tabTitle(section.tab)
        }
    }

    // MARK: Sidebar

    static let macSidebarSubtitle = "AIアプリ"
    static let macSidebarSections = "Sections"
    static let macConnection = "Connection"
    static let macConnectionDetail = "接続状態"

    // MARK: Empty detail columns

    static let macNoChatTitle = "会話を選んでください"
    static let macNoChatBody = "左の一覧から相手かグループを選ぶと、ここに会話が開きます。"
    static let macNoConversationTitle = "会話が開いていません"
    static let macNoConversationBody = "一覧から会話を選ぶか、⌘Nで新しい会話を始めてください。"

    // MARK: Menus

    static let macMenuGo = "Go"
    static let macMenuChat = "Chat"
    static let macToggleSidebar = "Toggle Sidebar"
    static let macNewChat = "New Chat"
    static let macSearch = "Search"
    static let macReload = "Reload"
    static let macSettingsMenu = "Settings…"
    static let macCloseConversation = "Close Conversation"
}
#endif
