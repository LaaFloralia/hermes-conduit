#if LAA_BUILD && DEBUG && os(iOS) && targetEnvironment(simulator)
import Foundation
import UserNotifications

/// `-LAA_AMBIENT_NOTIFICATION_FIXTURE`: a Debug simulator launch schedules
/// Monet's report and Morgan's decision as local notifications, decorated
/// the way the notification service extension decorates a push
/// (LAANotificationStaffArt.staff, .attachment, .decorate), so the banner
/// with its mascot can be photographed. `simctl push` does not start the
/// extension on the simulator; this shows what it attaches, nothing is sent.
enum LAAAmbientNotificationFixture {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-LAA_AMBIENT_NOTIFICATION_FIXTURE") }

    static func startIfRequested() {
        guard requested else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted, let bundle = stills() else { return }
            let items: [(kind: String, hint: String?, title: String, body: String, delay: TimeInterval)] = [
                ("monet.report", nil, "Monet", "朝の報告をまとめました。", 5),
                ("decision.new", "laa-cfo", "判断待ち", "今月の経費の締め方を選んでください。", 11),
            ]
            for item in items {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                LAANotificationStaffArt.decorate(content, kind: item.kind, profile: "laa-monet", staffHint: item.hint) {
                    LAANotificationStaffArt.attachment($0, bundle: bundle)
                }
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: item.delay, repeats: false)
                center.add(UNNotificationRequest(identifier: "laa-ambient-fixture-\(item.kind)", content: content, trigger: trigger))
            }
        }
    }

    /// The extension's layout (staff/<id>.png) made from the app's copy of
    /// the adopted stills (staff/<id>/<id>-avatar-512.png).
    private static func stills() -> Bundle? {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("staff") else { return nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("laa-ambient-fixture", isDirectory: true)
        let staff = root.appendingPathComponent("staff", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: staff, withIntermediateDirectories: true)
        for member in LAAStaff.allCases {
            let name = LAANotificationStaffArt.resourceName(member)
            let file = source.appendingPathComponent("\(name)/\(name)-avatar-512.png")
            try? FileManager.default.copyItem(at: file, to: staff.appendingPathComponent("\(name).png"))
        }
        return Bundle(url: root)
    }
}
#endif
