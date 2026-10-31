#if LAA_BUILD
import Foundation

enum LAADriveShortcutError: Error, Equatable {
    case invalidTarget, resourceKeyRequired, permissionUnknown, cycle, tooManyLinks

    var message: String {
        switch self {
        case .invalidTarget: return "The shortcut target is unavailable."
        case .resourceKeyRequired: return "This shortcut needs a resource key. Open it in Drive."
        case .permissionUnknown: return "The shortcut's access requirements are unavailable."
        case .cycle: return "This shortcut leads back to a folder or shortcut already open."
        case .tooManyLinks: return "There are too many shortcuts to follow."
        }
    }
}

/// Each target gets its own authenticated metadata request. Metadata access
/// does not imply permission to download a file; the eventual preview/save
/// still checks that permission separately.
@MainActor
enum LAADriveShortcutResolver {
    typealias MetadataLoader = @MainActor (_ id: String) async throws -> LAADriveListingItem

    static func resolve(_ entry: LAADriveListingItem, visitedFolderIDs: Set<String> = [],
                        maxHops: Int = 16, metadata: MetadataLoader) async throws -> LAADriveListingItem {
        guard maxHops > 0 else { throw LAADriveShortcutError.tooManyLinks }
        var visited = visitedFolderIDs
        guard visited.insert(entry.id).inserted else { throw LAADriveShortcutError.cycle }
        var current = entry
        var hops = 0
        while current.item.kind == "shortcut" {
            try Task.checkCancellation()
            guard hops < maxHops else { throw LAADriveShortcutError.tooManyLinks }
            guard let shortcut = current.shortcut else { throw LAADriveShortcutError.invalidTarget }
            guard let requiresKey = shortcut.requiresResourceKey else { throw LAADriveShortcutError.permissionUnknown }
            guard !requiresKey else { throw LAADriveShortcutError.resourceKeyRequired }
            guard let target = shortcut.targetId, (try? LAADrivePaths.metadata(target)) != nil else {
                throw LAADriveShortcutError.invalidTarget
            }
            guard visited.insert(target).inserted else { throw LAADriveShortcutError.cycle }
            let resolved = try await metadata(target)
            try Task.checkCancellation()
            guard resolved.id == target else { throw LAADriveShortcutError.invalidTarget }
            current = resolved
            hops += 1
        }
        return current
    }
}
#endif
