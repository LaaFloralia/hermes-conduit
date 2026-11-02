#if LAA_BUILD
import Foundation
import Combine

@MainActor final class LAALinearTaskRoute: ObservableObject {
    struct Target: Identifiable { let id: String }
    static let shared = LAALinearTaskRoute()
    @Published var target: Target?

    static func issueID(from url: URL) -> String? {
        guard url.scheme == "laa", url.host == "work", url.query == nil, url.fragment == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "tasks", !parts[1].isEmpty, parts[1].count <= 200,
              parts[1].unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_:".unicodeScalars.contains($0) }) else { return nil }
        return parts[1]
    }
    @discardableResult func open(_ url: URL) -> Bool {
        guard let id = Self.issueID(from: url) else { return false }
        target = Target(id: id)
        return true
    }
}
#endif
