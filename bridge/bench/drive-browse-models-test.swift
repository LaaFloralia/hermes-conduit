import Foundation

@main private struct DriveBrowseFixture {
    static func main() throws {
        for section in LAADriveBrowseSection.allCases {
            let query = LAADriveBrowseQuery(section: section, folderID: "folder_1", search: "a+b & 雪", cursor: "a+b/=", pageSize: 9)
            let path = query.path!
            precondition(path.contains("%2B"))
            let parts = URLComponents(string: path)!
            let fields = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value!) })
            precondition(fields["view"] == section.rawValue && fields["folderId"] == "folder_1")
            precondition(fields["query"] == "a+b & 雪" && fields["cursor"] == "a+b/=" && fields["pageSize"] == "9")
        }
        precondition(LAADriveBrowseQuery(section: .my, folderID: "../etc").path == nil)
        precondition(LAADriveBrowseQuery(section: .my, pageSize: 201).path == nil)
        precondition(LAADriveBrowseQuery(section: .my, pageSize: 0).path == nil)
        precondition(LAADriveBrowseQuery(section: .my, search: String(repeating: "🎄", count: 100)).path != nil)
        precondition(LAADriveBrowseQuery(section: .my, search: String(repeating: "🎄", count: 101)).path == nil)

        let json = Data("""
        {"items":[
          {"id":"file01","name":"movie.mp4","mimeType":"video/mp4","kind":"file","size":123,
           "version":"9007199254740993","parents":["folder01"],"downloadable":true,"starred":true,
           "viewedAt":"2026-10-01T00:00:00Z","hasThumbnail":true,"thumbnailVersion":"17",
           "webViewLink":"https://drive.google.com/file/d/file01/view"},
          {"id":"short01","name":"folder link","mimeType":"application/vnd.google-apps.shortcut","kind":"shortcut",
           "version":"3","shortcut":{"targetId":"folder01","targetMimeType":"application/vnd.google-apps.folder","requiresResourceKey":false},
           "webViewLink":"https://drive.google.com.evil.example/path"},
          {"id":"short02","name":"blocked link","mimeType":"application/vnd.google-apps.shortcut","kind":"shortcut",
           "version":"3x","shortcut":{"targetId":"folder02","requiresResourceKey":true}}
        ],"nextCursor":"page-two","incompleteSearch":true}
        """.utf8)
        let page = try JSONDecoder().decode(LAADriveListingPage.self, from: json)
        precondition(page.items.count == 3 && page.nextCursor == "page-two" && page.incompleteSearch == true)
        let first = page.items[0]
        precondition(first.id == "file01" && first.item.isMedia && first.version == "9007199254740993")
        precondition(first.parents == ["folder01"] && first.starred == true && first.hasThumbnail == true && first.thumbnailVersion == "17")
        precondition(first.safeWebViewURL?.host == "drive.google.com")
        let shortcut = page.items[1]
        precondition(shortcut.safeWebViewURL == nil)
        precondition(shortcut.shortcut?.targetID(visited: ["root01"]) == "folder01")
        precondition(shortcut.shortcut?.targetID(visited: ["folder01"]) == nil)
        precondition(page.items[2].version == nil && page.items[2].shortcut?.targetID(visited: []) == nil)
        let oldPage = try JSONDecoder().decode(LAADriveListingPage.self, from: Data("{\"items\":[],\"nextCursor\":null}".utf8))
        precondition(oldPage.incompleteSearch == nil)
        print("Drive browse models fixture passed")
    }
}
