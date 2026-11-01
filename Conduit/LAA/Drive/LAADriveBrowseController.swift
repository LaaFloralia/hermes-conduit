#if LAA_BUILD
import Combine
import Foundation

enum LAADriveBrowseError: Error, Equatable { case invalidQuery, invalidPage, cursorExpired }

/// Keeps each response tied to its original section, folder, search and
/// pairing revision. The view owns navigation and provides the Bridge loader.
@MainActor
final class LAADriveBrowseController: ObservableObject {
    typealias Loader = @MainActor (LAADriveBrowseQuery) async throws -> LAADriveListingPage

    @Published private(set) var items: [LAADriveListingItem] = []
    @Published private(set) var cursor: String?
    @Published private(set) var loading = false
    @Published private(set) var error: Error?
    @Published private(set) var incompleteSearch: Bool?

    private var query: LAADriveBrowseQuery?
    private var generation: UInt64 = 0
    private var seenCursors: Set<String> = []

    /// Discards old-pairing results immediately, even if a request ignores cancellation.
    func invalidate() {
        generation &+= 1
        query = nil; items = []; cursor = nil; seenCursors = []
        loading = false; error = nil; incompleteSearch = nil
    }

    func reload(_ requested: LAADriveBrowseQuery, using load: Loader) async {
        generation &+= 1
        let expectedGeneration = generation
        let initial = LAADriveBrowseQuery(section: requested.section, folderID: requested.folderID,
                                          search: requested.search, pageSize: requested.pageSize)
        query = initial; items = []; cursor = nil; seenCursors = []
        incompleteSearch = nil; error = nil
        guard initial.path != nil else { loading = false; error = LAADriveBrowseError.invalidQuery; return }
        loading = true
        do {
            let page = try await load(initial)
            try Task.checkCancellation()
            guard generation == expectedGeneration else { return }
            items = unique(page.items)
            incompleteSearch = page.incompleteSearch
            if page.nextCursor == "" { error = LAADriveBrowseError.invalidPage }
            else { cursor = page.nextCursor }
            loading = false
        } catch is CancellationError {
            if generation == expectedGeneration { loading = false }
        } catch {
            guard generation == expectedGeneration else { return }
            self.error = error; loading = false
        }
    }

    func loadMore(using load: Loader) async {
        guard !loading, let base = query, let previous = cursor else { return }
        let requested = LAADriveBrowseQuery(section: base.section, folderID: base.folderID,
                                            search: base.search, cursor: previous, pageSize: base.pageSize)
        let expectedGeneration = generation
        loading = true; error = nil
        do {
            let page = try await load(requested)
            try Task.checkCancellation()
            guard generation == expectedGeneration, cursor == previous else { return }
            var existing = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { existing.insert($0.id).inserted })
            incompleteSearch = combined(incompleteSearch, page.incompleteSearch)
            seenCursors.insert(previous)
            if let next = page.nextCursor, next.isEmpty || seenCursors.contains(next) {
                cursor = nil; error = LAADriveBrowseError.invalidPage
            } else { cursor = page.nextCursor }
            loading = false
        } catch is CancellationError {
            if generation == expectedGeneration, cursor == previous { loading = false }
        } catch let failure as LAABridgeHTTPError where
            (failure.status == 410 && failure.code == "cursor_expired") ||
            (failure.status == 400 && failure.code == "cursor_invalid") {
            guard generation == expectedGeneration, cursor == previous else { return }
            cursor = nil; error = LAADriveBrowseError.cursorExpired; loading = false
        } catch {
            guard generation == expectedGeneration, cursor == previous else { return }
            self.error = error; loading = false
        }
    }

    private func unique(_ values: [LAADriveListingItem]) -> [LAADriveListingItem] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }
    }

    /// A missing signal from any page stays unknown unless another page says
    /// results are incomplete.
    private func combined(_ a: Bool?, _ b: Bool?) -> Bool? {
        if a == true || b == true { return true }
        if a == false && b == false { return false }
        return nil
    }
}
#endif
