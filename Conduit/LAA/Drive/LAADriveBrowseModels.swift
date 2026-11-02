#if LAA_BUILD
import Foundation

enum LAADriveBrowseSection: String, CaseIterable {
    case my, shared, sharedWithMe, recent, starred
}

/// A cursor belongs to this exact section, folder, query and page size.
struct LAADriveBrowseQuery: Hashable {
    let section: LAADriveBrowseSection
    let folderID: String?
    let search: String
    let cursor: String?
    let pageSize: Int

    init(section: LAADriveBrowseSection, folderID: String? = nil, search: String = "",
         cursor: String? = nil, pageSize: Int = 50) {
        self.section = section; self.folderID = folderID; self.search = search
        self.cursor = cursor; self.pageSize = pageSize
    }

    var path: String? {
        guard search.utf16.count <= 200, (1...200).contains(pageSize),
              folderID.map({ (try? LAADrivePaths.metadata($0)) != nil }) ?? true else { return nil }
        var components = URLComponents()
        components.path = "/v1/drive/files"
        var query = [URLQueryItem(name: "view", value: section.rawValue),
                     URLQueryItem(name: "pageSize", value: String(pageSize))]
        if let folderID { query.append(URLQueryItem(name: "folderId", value: folderID)) }
        if !search.isEmpty { query.append(URLQueryItem(name: "query", value: search)) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = query
        // URLSearchParams treats a literal + as space; preserve the search text.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.string
    }
}

struct LAADriveShortcut: Codable, Hashable {
    let targetId: String?
    let targetMimeType: String?
    let requiresResourceKey: Bool?

    /// A caller must still fetch target metadata and check permission.
    func targetID(visited: Set<String>) -> String? {
        guard requiresResourceKey == false, let targetId,
              (try? LAADrivePaths.metadata(targetId)) != nil, !visited.contains(targetId) else { return nil }
        return targetId
    }
}

/// Extends the existing item decoder without changing the shared Assets model.
struct LAADriveListingItem: Codable, Hashable, Identifiable {
    let item: LAADriveItem
    let version: String?
    let parents: [String]
    let starred: Bool?
    let viewedAt: String?
    let hasThumbnail: Bool?
    let thumbnailVersion: String?
    let shortcut: LAADriveShortcut?
    private let webViewLink: URL?
    var id: String { item.id }

    private enum Keys: String, CodingKey {
        case version, parents, starred, viewedAt, hasThumbnail, thumbnailVersion, shortcut, webViewLink
    }

    init(from decoder: Decoder) throws {
        item = try LAADriveItem(from: decoder)
        let values = try decoder.container(keyedBy: Keys.self)
        version = Self.validVersion(try values.decodeIfPresent(String.self, forKey: .version))
        parents = try values.decodeIfPresent([String].self, forKey: .parents) ?? []
        starred = try values.decodeIfPresent(Bool.self, forKey: .starred)
        viewedAt = try values.decodeIfPresent(String.self, forKey: .viewedAt)
        hasThumbnail = try values.decodeIfPresent(Bool.self, forKey: .hasThumbnail)
        thumbnailVersion = Self.validVersion(try values.decodeIfPresent(String.self, forKey: .thumbnailVersion))
        shortcut = try values.decodeIfPresent(LAADriveShortcut.self, forKey: .shortcut)
        webViewLink = try values.decodeIfPresent(URL.self, forKey: .webViewLink)
    }

    /// The destination receives no Bridge credential. Do not open arbitrary
    /// URLs returned by a malformed or outdated server.
    func encode(to encoder: Encoder) throws {
        try item.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encode(parents, forKey: .parents)
        try container.encodeIfPresent(starred, forKey: .starred)
        try container.encodeIfPresent(viewedAt, forKey: .viewedAt)
        try container.encodeIfPresent(hasThumbnail, forKey: .hasThumbnail)
        try container.encodeIfPresent(thumbnailVersion, forKey: .thumbnailVersion)
        try container.encodeIfPresent(shortcut, forKey: .shortcut)
        try container.encodeIfPresent(webViewLink, forKey: .webViewLink)
    }

    var safeWebViewURL: URL? {
        guard let url = webViewLink, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), ["drive.google.com", "docs.google.com"].contains(host) else { return nil }
        return url
    }

    private static func validVersion(_ value: String?) -> String? {
        guard let value, (1...30).contains(value.utf8.count),
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return value
    }
}

struct LAADriveListingPage: Codable {
    let items: [LAADriveListingItem]
    let nextCursor: String?
    /// Nil means the Bridge did not report whether results are incomplete.
    let incompleteSearch: Bool?
}
#endif
