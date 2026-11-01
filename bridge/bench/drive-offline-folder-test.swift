import Foundation

private func expect(_ value: Bool, _ message: String) {
    guard value else { fatalError(message) }
}

private func item(_ id: String, mime: String, kind: String = "file", size: Int? = nil,
                  downloadable: Bool? = true, version: String? = "1", exportFormats: [String]? = nil) -> [String: Any] {
    var value: [String: Any] = ["id": id, "name": id, "mimeType": mime, "kind": kind]
    if let size { value["size"] = size }
    if let downloadable { value["downloadable"] = downloadable }
    if let version { value["version"] = version }
    if let exportFormats { value["exportFormats"] = exportFormats }
    return value
}

private func page(_ items: [[String: Any]], cursor: String? = nil, incomplete: Bool? = false) throws -> LAADriveListingPage {
    var object: [String: Any] = ["items": items, "nextCursor": cursor as Any? ?? NSNull()]
    if let incomplete { object["incompleteSearch"] = incomplete }
    return try JSONDecoder().decode(LAADriveListingPage.self, from: JSONSerialization.data(withJSONObject: object))
}

private enum FixtureError: Error { case failed }

@main private struct OfflineFolderFixture {
    @MainActor
    static func main() async throws {
        let folder = item("fold_1", mime: "application/vnd.google-apps.folder", kind: "folder")
        let nested = item("fold_2", mime: "application/vnd.google-apps.folder", kind: "folder")
        let photo = item("photo1", mime: "image/png", size: 100)
        let pdf = item("pdf_01", mime: "application/pdf", size: 75)
        let workspace = item("doc_01", mime: "application/vnd.google-apps.document", kind: "workspace_document",
                             exportFormats: ["application/pdf"])
        let unknown = item("unk_01", mime: "audio/mpeg", size: 1, downloadable: nil)
        let denied = item("deny01", mime: "video/mp4", size: 1, downloadable: false)
        let shortcut = item("link01", mime: "application/vnd.google-apps.shortcut", kind: "shortcut")
        let noVersion = item("nover1", mime: "image/png", size: 1, version: nil)
        let plan = try await LAADriveOfflineFolder.plan(rootID: "root01") { folderID, cursor in
            switch (folderID, cursor) {
            case ("root01", nil): return try page([folder, photo, workspace, unknown, shortcut], cursor: "next", incomplete: nil)
            case ("root01", "next"): return try page([folder, photo, denied, noVersion])
            case ("fold_1", nil): return try page([pdf, nested])
            case ("fold_2", nil): throw FixtureError.failed
            default: fatalError("unexpected folder or cursor")
            }
        }
        expect(plan.files.map(\.id) == ["photo1", "doc_01", "pdf_01"] && plan.knownBytes == 175 &&
               plan.unknownSizeCount == 1, "files deduplicated; exported PDF size is unknown")
        let reasons = plan.issues.map(\.reason)
        expect(reasons.contains(.incompleteListing) && reasons.contains(.permissionUnknown) &&
               reasons.contains(.forbidden) && reasons.contains(.unsupported) &&
               reasons.contains(.versionUnavailable) && reasons.contains(.listingFailed), "partial plan reports every reason")
        var progress: [Int] = []
        let saved = await LAADriveOfflineFolder.save(plan, save: { file in
            if file.id == "doc_01" { throw FixtureError.failed }
        }, progress: { completed, _ in progress.append(completed) })
        expect(saved.savedIDs == ["photo1", "pdf_01"] && saved.failedIDs == ["doc_01"] && !saved.cancelled &&
               progress == [1, 2, 3], "partial save and progress")
        let cancelled = await LAADriveOfflineFolder.save(plan) { file in
            if file.id == "doc_01" { throw CancellationError() }
        }
        expect(cancelled.savedIDs == ["photo1"] && cancelled.failedIDs.isEmpty && cancelled.cancelled,
               "cancellation preserves already saved files")
        let loop = try await LAADriveOfflineFolder.plan(rootID: "root01") { _, _ in
            try page([], cursor: "same")
        }
        expect(loop.issues.contains(where: { $0.reason == .cursorLoop }), "cursor cycle is reported")
        let limited = try await LAADriveOfflineFolder.plan(rootID: "root01", maximumItems: 1) { _, _ in
            try page([photo, pdf])
        }
        expect(limited.files.map(\.id) == ["photo1"] && limited.issues.contains(where: { $0.reason == .limitReached }),
               "bounded plan reports truncation")
        let cancelledPlan = Task { @MainActor in
            try await LAADriveOfflineFolder.plan(rootID: "root01") { _, _ in try page([]) }
        }
        cancelledPlan.cancel()
        do { _ = try await cancelledPlan.value; fatalError("expected planning cancellation") } catch is CancellationError { }
        print("Drive offline folder fixture passed")
    }
}
