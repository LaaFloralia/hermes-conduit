// Imports outside the platform check: the shared block at the end of this file
// publishes menu commands from screens the phone also builds.
import Combine
import Foundation
import SwiftUI

#if LAA_BUILD && targetEnvironment(macCatalyst)

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
    /// The section the window shows, so a menu item about one section's
    /// content (the open conversation) knows whether it applies.
    @Published var activeSection: LAAMacSection = .chats
    /// Counters: each request bumps one, and the shell acts on the change.
    @Published var toggleSidebar = 0
    @Published var openSettings = 0
    @Published var closeConversation = 0
}

extension LAACopy {
    static func macSectionTitle(_ section: LAAMacSection) -> String {
        switch section {
        case .drive: return "Drive"
        default: return tabTitle(section.tab)
        }
    }

    // MARK: Menus

    static let macMenuGo = "移動"
    static let macToggleSidebar = "サイドバーを切り替える"
    static let macSearch = "検索"
    static let macReload = "再読み込み"
    static let macSettingsMenu = "設定…"
    static let macCloseConversation = "会話を閉じる"
}

#endif

#if LAA_BUILD
// The Mac's screens that share code with the phone publish these too, so the
// type cannot live in the Catalyst-only block above.

/// What the menu bar can do in the section the window shows. A section
/// publishes one for its column and the menu reads it as a focused value, so
/// each of ⌘N, ⌘F and ⌘R has one implementation: the one the shown section
/// provides. A section that publishes nothing — or has nothing to do the
/// command acts on — leaves the item greyed instead of silently doing nothing.
struct LAAMacSectionCommands {
    /// The File menu's new item names what it creates here.
    var newTitle: String = LAACopy.macNewChat
    var newShortcut: KeyEquivalent = "n"
    var newModifiers: EventModifiers = .command
    var canCreate = true
    var create: () -> Void = {}
    var canSearch = false
    var focusSearch: () -> Void = {}
    var canReload = false
    var reload: () -> Void = {}
}

private struct LAAMacSectionCommandsKey: FocusedValueKey {
    typealias Value = LAAMacSectionCommands
}

extension FocusedValues {
    var laaMacSectionCommands: LAAMacSectionCommands? {
        get { self[LAAMacSectionCommandsKey.self] }
        set { self[LAAMacSectionCommandsKey.self] = newValue }
    }
}

extension View {
    /// Offers this section's menu commands to the window's menu bar. Scene
    /// scope, not focus scope: the list keeps its own keyboard focus, and the
    /// menu still knows what the column can do. Mac only: the Mac shows one
    /// section at a time, but the phone keeps every tab alive, and several
    /// tabs writing the one scene value redrew each other without end.
    @ViewBuilder
    func laaMacSectionCommands(_ commands: LAAMacSectionCommands, enabled: Bool = true) -> some View {
        #if targetEnvironment(macCatalyst)
        if enabled {
            focusedSceneValue(\.laaMacSectionCommands, commands)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension LAACopy {
    /// The File menu's new item when the section names nothing else.
    static let macNewChat = "新しい会話"

    // MARK: Empty detail columns

    // One line each, in the reader's language: the rules keep operation
    // labels English and say what is missing in Japanese.
    static let macNoChatTitle = "会話を選んでください。"
    static let macNoSessionTitle = "セッションを選んでください。"
    static let macNoProjectTitle = "プロジェクトを選んでください。"
    static let macNoRoutineTitle = "定期実行を選んでください。"
    static let macNoSkillTitle = "スキルを選んでください。"
    static let macNoEventTitle = "予定を選んでください。"

    // MARK: List states

    static let macNoSessions = "セッションはまだありません。"
    static let macNoArchivedSessions = "アーカイブしたセッションはありません。"
    static let macNoProjects = "プロジェクトはまだありません。"
    static let macNoArchivedProjects = "アーカイブしたプロジェクトはありません。"
    static let macNoRoutines = "定期実行はありません。"
    static let macNoSkills = "スキルはありません。"
    static let macNoEvents = "この期間に予定はありません。"
    static let macSessionsUnreadable = "セッションを読み取れません。"
    static let macProjectsUnreadable = "プロジェクトを読み取れません。"
    static let macListUnreadable = "一覧を読み取れません。"
    static let macScheduleUnknown = "日程不明"
}
#endif
