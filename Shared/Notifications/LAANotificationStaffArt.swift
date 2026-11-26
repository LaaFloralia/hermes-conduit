#if LAA_BUILD
import Foundation
import UserNotifications

/// The employee whose mascot a notification carries (HO-08, contract C-2.5).
/// The image is a bundled still (`staff/<id>.png`, copied into the
/// notification extension at build time from `docs/laa/assets/staff`); it is
/// never fetched. A Communication Notification (sender avatar) would need the
/// communication-notifications capability on the App ID, which the LAA
/// account does not hold, so the attachment is the only form.
enum LAANotificationStaffArt {
    /// The attachment's identifier, so a notification carries one mascot.
    static let attachmentIdentifier = "laa-staff"

    /// Who the notification speaks for.
    /// - A Bridge notification (it has sealed metadata, `kind`) is Monet's
    ///   lane: `monet.report` is Monet, a decision is the asking employee the
    ///   Bridge names (`staffHint`) or Monet, and everything else the Bridge
    ///   sends (Work sessions, tasks, calendar) is Monet.
    /// - Any other push (a chat reply, a routine's report) is the profile it
    ///   came from, when that profile is an LAA employee.
    /// Nil leaves the notification without an image.
    static func staff(kind: String?, profile: String?, staffHint: String?) -> LAAStaff? {
        if let kind, !kind.isEmpty {
            if kind.hasPrefix("decision."), let hint = staffHint.flatMap(LAAStaff.init(profile:)) {
                return hint
            }
            return .monet
        }
        guard let profile else { return nil }
        return LAAStaff(profile: profile)
    }

    /// The bundled file's name for `staff`. Dots has no mascot of its own and
    /// uses Monet's, as everywhere else in the app.
    static func resourceName(_ staff: LAAStaff) -> String {
        (staff == .monetDots ? LAAStaff.monet : staff).rawValue
    }

    /// The bundled still, or nil when the build carries none for `staff`.
    static func bundledImage(_ staff: LAAStaff, root: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        let url = root.appendingPathComponent("staff", isDirectory: true)
            .appendingPathComponent("\(resourceName(staff)).png")
        return exists(url) ? url : nil
    }

    /// A copy of the still in the extension's temporary folder, attached.
    /// The system moves an attachment's file into its own store, and the
    /// bundle's copy cannot be moved, so it is copied first. Any failure
    /// leaves the notification as it was.
    static func attachment(_ staff: LAAStaff, bundle: Bundle = .main, fileManager: FileManager = .default) -> UNNotificationAttachment? {
        guard let source = bundledImage(staff, root: bundle.resourceURL ?? bundle.bundleURL) else { return nil }
        let folder = fileManager.temporaryDirectory.appendingPathComponent("laa-staff-\(UUID().uuidString)", isDirectory: true)
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: copy)
            return try UNNotificationAttachment(identifier: attachmentIdentifier, url: copy, options: [
                UNNotificationAttachmentOptionsTypeHintKey: "public.png",
            ])
        } catch {
            try? fileManager.removeItem(at: folder)
            return nil
        }
    }

    /// Adds the mascot unless the notification already carries an image.
    static func decorate(_ content: UNMutableNotificationContent, kind: String?, profile: String?, staffHint: String?,
                         make: (LAAStaff) -> UNNotificationAttachment? = { LAANotificationStaffArt.attachment($0) }) {
        guard content.attachments.isEmpty,
              let staff = staff(kind: kind, profile: profile, staffHint: staffHint),
              let attachment = make(staff) else { return }
        content.attachments = [attachment]
    }
}

/// When Monet's last report arrived, kept in the notification App Group by
/// the extension so the app can tell the Apple Watch (LAAWatchAmbient). Only
/// the time is kept: no title, body or link leaves the notification.
enum LAAMonetReportLedger {
    static let key = "laa.ambient.lastMonetReportAt"

    static func note(kind: String?, at date: Date = Date(), defaults: UserDefaults? = NotificationSharedSettings.defaults) {
        guard kind == "monet.report", let defaults else { return }
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }

    static func lastReport(defaults: UserDefaults? = NotificationSharedSettings.defaults) -> Date? {
        guard let value = defaults?.double(forKey: key), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}
#endif
