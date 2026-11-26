import Foundation
import Observation

/// The owner's theme-set choice, shared with widgets and extensions through the app's App Group.
/// The kit never names an App Group: each app passes its own (identifiers stay frozen in the app).
@MainActor
@Observable
public final class LAAThemeStore {
    public nonisolated static let defaultsKey = "laa.theme.set"
    public private(set) var themeID: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// - Parameter appGroup: the app's App Group (`group.…`), or nil for standard defaults (previews, tests).
    public init(appGroup: String?) {
        defaults = appGroup.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let stored = defaults.string(forKey: Self.defaultsKey)
        themeID = LAAThemeSets.set(id: stored).id
        // Rewrite a renamed identifier once, so widgets and other readers see the current one.
        if let stored, LAAThemeSets.renamedIDs[stored] != nil { defaults.set(themeID, forKey: Self.defaultsKey) }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    public var theme: LAAThemeSet { LAAThemeSets.set(id: themeID) }

    public func select(_ id: String) {
        let resolved = LAAThemeSets.set(id: id).id
        guard resolved != themeID else { return }
        themeID = resolved
        defaults.set(resolved, forKey: Self.defaultsKey)
    }

    /// Re-read after another process (widget, keyboard) or the app wrote the shared value.
    public func reload() {
        let stored = LAAThemeSets.set(id: defaults.string(forKey: Self.defaultsKey)).id
        if stored != themeID { themeID = stored }
    }

    /// Non-isolated read for widget timelines and extensions.
    public nonisolated static func storedThemeID(appGroup: String?) -> String {
        let defaults = appGroup.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        return LAAThemeSets.set(id: defaults.string(forKey: defaultsKey)).id
    }
}
