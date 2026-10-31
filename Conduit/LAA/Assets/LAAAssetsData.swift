#if LAA_BUILD
import Foundation
#if DEBUG
import UIKit
#endif

extension LAACopy {
    enum Assets {
        static let title = "Assets"
        static let subtitle = "Everything you have made and saved."
        static let drive = "Drive"
        static let inspiration = "Inspiration"
        static let studio = "Studio"
        static let search = "Search assets"
        static let unavailable = "Inspiration is not available yet."
        static let configureDrive = "Drive authorization is not configured on the Mac."
        static let scope = "This device needs the media:read permission."
        static let empty = "No items found."
        static let files = "Files"
        static let file = "File"
        static let image = "Image"
        static let document = "Document"
        static let folder = "Folder"
        static let filter = "Filter"
        static let all = "All"
        static let images = "Images"
        static let documents = "Documents"
        static let folders = "Folders"
        static let loadedOnly = "Filters apply to loaded items."
        static let loadMore = "Load more"
        static let searchTooLong = "Search text is too long."
    }
}

struct LAADriveItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let mimeType: String
    let kind: String
    let version: String?
    let size: Int64?
    let modifiedAt: String?
    let downloadable: Bool?
    let exportFormats: [String]?
    let thumbnailLink: URL?
    let owners: [LAADriveOwner]?

    var isFolder: Bool { kind == "folder" }
    var isImage: Bool { mimeType.hasPrefix("image/") }
    var isMedia: Bool { mimeType.hasPrefix("video/") || mimeType.hasPrefix("audio/") }
    var isPDF: Bool { mimeType == "application/pdf" }
    var isWorkspace: Bool { kind == "workspace_document" }
    var isDocument: Bool {
        !isFolder && (mimeType.hasPrefix("text/") || mimeType == "application/pdf" ||
                      mimeType == "application/msword" || mimeType.hasPrefix("application/vnd.openxmlformats-officedocument.") ||
                      kind == "workspace_document")
    }
    var symbol: String { isFolder ? "folder" : isImage ? "photo" : isMedia ? "play.rectangle" : "doc.text" }
    var kindTitle: String {
        isFolder ? LAACopy.Assets.folder : isImage ? LAACopy.Assets.image : isDocument ? LAACopy.Assets.document : LAACopy.Assets.file
    }
}

struct LAADriveOwner: Decodable, Hashable {
    let displayName: String?
}

struct LAADrivePage: Decodable {
    let items: [LAADriveItem]
    let nextCursor: String?
}

enum LAADriveFilter: String, CaseIterable {
    case all, images, documents, folders
    var title: String {
        switch self {
        case .all: return LAACopy.Assets.all
        case .images: return LAACopy.Assets.images
        case .documents: return LAACopy.Assets.documents
        case .folders: return LAACopy.Assets.folders
        }
    }
    func contains(_ item: LAADriveItem) -> Bool {
        switch self {
        case .all: return true
        case .images: return item.isImage
        case .documents: return item.isDocument
        case .folders: return item.isFolder
        }
    }
}

enum LAADriveData {
    static func path(query: String, folderID: String?, cursor: String?) -> String? {
        guard query.utf16.count <= 200 else { return nil }
        var parts = URLComponents()
        parts.path = "/v1/drive/files"
        var items: [URLQueryItem] = []
        if !query.isEmpty { items.append(URLQueryItem(name: "query", value: query)) }
        if let folderID { items.append(URLQueryItem(name: "folderId", value: folderID)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        if !items.isEmpty { parts.queryItems = items }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.string
    }

    #if DEBUG
    static var snapshotFixture: String?
    static var fixture: String? {
        if let snapshotFixture { return snapshotFixture }
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-laa-assets-fixture"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    #endif

    @MainActor static func available(_ bridge: LAABridgeSession) -> Bool {
        #if DEBUG
        if fixture != nil { return true }
        #endif
        return bridge.status == .paired
    }

    #if DEBUG
    private static func fixturePage(path: String) throws -> Data? {
        if let fixture {
            if fixture == "offline" { throw LAABridgeError.networkUnreachable }
            if fixture == "error" {
                throw LAABridgeHTTPError(status: 500, code: "fetch_failed", message: nil,
                                         retryable: false, details: nil, requestId: nil, currentETag: nil)
            }
            if fixture == "unconfigured" {
                throw LAABridgeHTTPError(status: 503, code: "drive_not_configured", message: nil,
                                         retryable: false, details: nil, requestId: nil, currentETag: nil)
            }
            if fixture == "scopeDenied" {
                throw LAABridgeHTTPError(status: 403, code: "insufficient_scope", message: nil,
                                         retryable: false, details: nil, requestId: nil, currentETag: nil)
            }
            let components = URLComponents(string: path)
            let folder = components?.queryItems?.first(where: { $0.name == "folderId" })?.value
            let search = components?.queryItems?.first(where: { $0.name == "query" })?.value
            let cursor = components?.queryItems?.first(where: { $0.name == "cursor" })?.value
            var objects: [[String: String]] = fixture == "empty" ? [] : folder == "folder1" ? [
                ["id": "doc2", "name": "Inside", "mimeType": "application/pdf", "kind": "file"]
            ] : [
                ["id": "folder1", "name": "Projects", "mimeType": "application/vnd.google-apps.folder", "kind": "folder"],
                ["id": "image1", "name": "Portrait", "mimeType": "image/png", "kind": "file"],
                ["id": "doc1", "name": "Notes", "mimeType": "application/pdf", "kind": "file"],
                ["id": "video1", "name": "Sample video", "mimeType": "video/quicktime", "kind": "file"],
                ["id": "workspace1", "name": "Workspace document", "mimeType": "application/vnd.google-apps.document", "kind": "workspace_document"]
            ]
            if fixture == "paged" {
                objects = cursor == nil ? Array(objects.prefix(1)) : Array(objects.dropFirst(1))
            }
            if let search, !search.isEmpty { objects = objects.filter { $0["name"]?.localizedCaseInsensitiveContains(search) == true } }
            let next: Any = fixture == "paged" && cursor == nil ? "page2" : NSNull()
            let enriched: [[String: Any]] = objects.map { object in
                var result: [String: Any] = object
                result["version"] = "1"
                result["downloadable"] = true
                result["size"] = 1024
                result["hasThumbnail"] = false
                result["exportFormats"] = object["kind"] == "workspace_document" ? ["application/pdf"] : []
                return result
            }
            return try JSONSerialization.data(withJSONObject: ["items": enriched, "nextCursor": next, "incompleteSearch": false])
        }
        return nil
    }
    #endif

    @MainActor static func page(path: String, bridge: LAABridgeSession) async throws -> LAADrivePage {
        #if DEBUG
        if let data = try fixturePage(path: path) { return try JSONDecoder().decode(LAADrivePage.self, from: data) }
        #endif
        let result: LAABridgeResponse<LAADrivePage> = try await bridge.request(method: "GET", path: path)
        return result.data
    }

    @MainActor static func listingPage(_ query: LAADriveBrowseQuery, bridge: LAABridgeSession) async throws -> LAADriveListingPage {
        guard let path = query.path else { throw LAABridgeError.invalidResponse }
        #if DEBUG
        if let data = try fixturePage(path: path) { return try JSONDecoder().decode(LAADriveListingPage.self, from: data) }
        #endif
        let result: LAABridgeResponse<LAADriveListingPage> = try await bridge.request(method: "GET", path: path)
        return result.data
    }

    @MainActor static func listingMetadata(_ id: String, bridge: LAABridgeSession) async throws -> LAADriveListingItem {
        let path = try LAADrivePaths.metadata(id)
        #if DEBUG
        if fixture != nil {
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "name": id, "mimeType": "application/pdf",
                                                                    "kind": "file", "version": "1", "downloadable": true])
            return try JSONDecoder().decode(LAADriveListingItem.self, from: data)
        }
        #endif
        let result: LAABridgeResponse<LAADriveListingItem> = try await bridge.request(method: "GET", path: path)
        return result.data
    }

    @MainActor static func metadata(_ item: LAADriveItem, bridge: LAABridgeSession) async throws -> LAADriveItem {
        #if DEBUG
        if fixture != nil {
            let fixtureSize: Int64
            if item.isWorkspace { fixtureSize = 0 }
            else { fixtureSize = (try? await LAADriveContent.range(item, offset: 0, length: 1, bridge: bridge).total) ?? 1024 }
            let data = try JSONSerialization.data(withJSONObject: [
                "id": item.id, "name": item.name, "mimeType": item.mimeType, "kind": item.kind,
                "size": fixtureSize, "version": "1", "modifiedAt": "2026-10-25T13:00:00.000Z", "downloadable": true,
                "exportFormats": item.isWorkspace ? ["application/pdf"] : []
            ])
            return try JSONDecoder().decode(LAADriveItem.self, from: data)
        }
        #endif
        let path = try LAADrivePaths.metadata(item.id)
        let result: LAABridgeResponse<LAADriveItem> = try await bridge.request(method: "GET", path: path)
        return result.data
    }

    @MainActor static func exportPDF(_ item: LAADriveItem, bridge: LAABridgeSession,
                                     expectedVersion: String?) async throws -> LAADrivePDFExport {
        #if DEBUG
        if fixture != nil {
            guard expectedVersion == nil || expectedVersion == "1" else { throw LAADrivePDFExportError.versionChanged }
            let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { context in
                context.beginPage()
                "Fixture document".draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
            }
            return LAADrivePDFExport(data: data, version: "1")
        }
        #endif
        return try await bridge.driveExportPDF(id: item.id, expectedVersion: expectedVersion)
    }
}
#endif
