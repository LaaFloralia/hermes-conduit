#if LAA_BUILD
import Foundation

struct LAADriveOfflineFolderIssue {
    enum Reason {
        case listingFailed, incompleteListing, cursorLoop, limitReached
        case invalidItem, permissionUnknown, forbidden, versionUnavailable, sizeUnavailable, unsupported
    }
    let id: String
    let reason: Reason
}

struct LAADriveOfflineFolderPlan {
    let files: [LAADriveListingItem]
    let knownBytes: Int64
    /// Workspace PDFs have no known output size before export.
    let unknownSizeCount: Int
    let issues: [LAADriveOfflineFolderIssue]
}

struct LAADriveOfflineFolderResult {
    let savedIDs: [String]
    let failedIDs: [String]
    let cancelled: Bool
}

/// Enumerates a folder without assuming every page or file is accessible.
/// Actual saves must still recheck permission and version in the offline store.
@MainActor
enum LAADriveOfflineFolder {
    typealias Loader = @MainActor (_ folderID: String, _ cursor: String?) async throws -> LAADriveListingPage
    typealias Saver = @MainActor (LAADriveListingItem) async throws -> Void

    static func plan(rootID: String, maximumItems: Int = 10_000, maximumPages: Int = 1_000,
                     load: Loader) async throws -> LAADriveOfflineFolderPlan {
        guard (try? LAADrivePaths.metadata(rootID)) != nil, maximumItems > 0, maximumPages > 0 else {
            throw LAADriveOfflineError.invalidItem
        }
        var pending = [rootID]
        var nextFolder = 0
        var visited: Set<String> = [rootID]
        var seenFiles: Set<String> = []
        var files: [LAADriveListingItem] = []
        var issues: [LAADriveOfflineFolderIssue] = []
        var knownBytes: Int64 = 0
        var unknownSizeCount = 0
        var itemCount = 0
        var pageCount = 0

        folderLoop: while nextFolder < pending.count {
            let folder = pending[nextFolder]
            nextFolder += 1
            var cursor: String?
            var seenCursors: Set<String> = []
            repeat {
                try Task.checkCancellation()
                guard pageCount < maximumPages else {
                    issues.append(.init(id: folder, reason: .limitReached)); break folderLoop
                }
                pageCount += 1
                let page: LAADriveListingPage
                do { page = try await load(folder, cursor) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    issues.append(.init(id: folder, reason: .listingFailed))
                    break
                }
                try Task.checkCancellation()
                if page.incompleteSearch != false { issues.append(.init(id: folder, reason: .incompleteListing)) }
                for entry in page.items {
                    guard itemCount < maximumItems else {
                        issues.append(.init(id: folder, reason: .limitReached)); break folderLoop
                    }
                    itemCount += 1
                    let item = entry.item
                    guard (try? LAADrivePaths.metadata(item.id)) != nil else {
                        issues.append(.init(id: item.id, reason: .invalidItem)); continue
                    }
                    if item.isFolder {
                        if visited.insert(item.id).inserted { pending.append(item.id) }
                        continue
                    }
                    guard seenFiles.insert(item.id).inserted else { continue }
                    // Shortcuts require a separately authorized target lookup;
                    // do not silently follow them during a bulk save.
                    guard item.isImage || item.isMedia || item.isPDF || item.isWorkspace else {
                        issues.append(.init(id: item.id, reason: .unsupported)); continue
                    }
                    guard item.downloadable != false else {
                        issues.append(.init(id: item.id, reason: .forbidden)); continue
                    }
                    guard item.downloadable == true else {
                        issues.append(.init(id: item.id, reason: .permissionUnknown)); continue
                    }
                    guard entry.version != nil else {
                        issues.append(.init(id: item.id, reason: .versionUnavailable)); continue
                    }
                    if item.isWorkspace {
                        guard item.exportFormats?.contains("application/pdf") == true else {
                            issues.append(.init(id: item.id, reason: .unsupported)); continue
                        }
                        unknownSizeCount += 1
                    } else {
                        guard let size = item.size, size >= 0 else {
                            issues.append(.init(id: item.id, reason: .sizeUnavailable)); continue
                        }
                        let (sum, overflow) = knownBytes.addingReportingOverflow(size)
                        guard !overflow else {
                            issues.append(.init(id: item.id, reason: .sizeUnavailable)); continue
                        }
                        knownBytes = sum
                    }
                    files.append(entry)
                }
                if let next = page.nextCursor {
                    guard !next.isEmpty, seenCursors.insert(next).inserted else {
                        issues.append(.init(id: folder, reason: .cursorLoop)); break
                    }
                    cursor = next
                } else { cursor = nil }
            } while cursor != nil
        }
        return .init(files: files, knownBytes: knownBytes, unknownSizeCount: unknownSizeCount, issues: issues)
    }

    /// Saves one file at a time so failure or cancellation can be reported as
    /// partial completion without removing any file already saved.
    static func save(_ plan: LAADriveOfflineFolderPlan, save: Saver,
                     progress: @MainActor (_ completed: Int, _ total: Int) -> Void = { _, _ in }) async -> LAADriveOfflineFolderResult {
        var saved: [String] = []
        var failed: [String] = []
        for file in plan.files {
            if Task.isCancelled { return .init(savedIDs: saved, failedIDs: failed, cancelled: true) }
            do {
                try await save(file)
                saved.append(file.id)
            } catch is CancellationError {
                return .init(savedIDs: saved, failedIDs: failed, cancelled: true)
            } catch {
                if Task.isCancelled { return .init(savedIDs: saved, failedIDs: failed, cancelled: true) }
                failed.append(file.id)
            }
            progress(saved.count + failed.count, plan.files.count)
        }
        return .init(savedIDs: saved, failedIDs: failed, cancelled: Task.isCancelled)
    }
}
#endif
