#if LAA_BUILD
import Foundation

/// Static identities are independent of the last widget snapshot. Profiles are
/// validated by the app against the selected dashboard when a link is opened.
enum LAAWidgetEmployee: String, CaseIterable {
    case ciel, argus, cfo, cio, cmo, cos, cto, cso

    static let defaultEmployee: Self = .ciel

    var name: String {
        switch self {
        case .ciel: "Ciel"
        case .argus: "Argus"
        case .cfo: "Morgan"
        case .cio: "Sherlock"
        case .cmo: "Monet"
        case .cos: "Merlin"
        case .cto: "Ada"
        case .cso: "Talos"
        }
    }

    var role: String {
        switch self {
        case .ciel: "社長秘書"
        case .argus: "トレード"
        case .cfo: "財務"
        case .cio: "情報"
        case .cmo: "広報・制作"
        case .cos: "業務管理"
        case .cto: "技術"
        case .cso: "セキュリティ"
        }
    }

    var profile: String { "laa-\(rawValue)" }
    var heroImage: String { "LAAEmployee-\(rawValue)-hero" }
    var avatarImage: String { "LAAEmployee-\(rawValue)-avatar" }

    static func forProfile(_ profile: String) -> Self? {
        allCases.first { $0.profile == profile }
    }
}

enum LAAEmployeeWidgetLinks {
    /// A widget can be added before the app has published a dashboard. The
    /// app resolves this sentinel to its current dashboard at delivery time.
    static let unresolvedDashboard = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let missingDashboardMessage = "Hermes の接続先がありません。アプリで接続してください。"
    static let missingProfileMessage = "社員のプロフィールが見つかりません。Hermes の設定を確認してください。"
    static let offlineMessage = "Hermes に接続できません。接続を確認してからお試しください。"

    static func link(employee: LAAWidgetEmployee, action: WidgetLaunchAction, snapshot: WidgetSnapshot?) -> WidgetLaunchLink {
        precondition(action == .employeeChat || action == .talk)
        let workspace = WidgetWorkspaceID(
            dashboardID: snapshot?.currentWorkspaceID?.dashboardID ?? unresolvedDashboard,
            profile: employee.profile
        )
        guard let link = WidgetLaunchLink(action: action, workspace: workspace, reference: nil) else {
            preconditionFailure("Static employee widget target must be valid")
        }
        return link
    }
}
#endif
