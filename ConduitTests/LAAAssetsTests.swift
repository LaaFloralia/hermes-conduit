#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAAAssetsTests: XCTestCase {
    private func item(_ name: String, mime: String, kind: String) throws -> LAADriveItem {
        let data = try JSONSerialization.data(withJSONObject: ["id": name, "name": name, "mimeType": mime, "kind": kind])
        return try JSONDecoder().decode(LAADriveItem.self, from: data)
    }

    func testDriveQueryPreservesSpecialCharactersAndCursor() throws {
        let path = try XCTUnwrap(LAADriveData.path(query: "色 & C++", folderID: "folder-1", cursor: "a+b/c"))
        let values = try XCTUnwrap(URLComponents(string: path)?.queryItems)
        XCTAssertEqual(values.first(where: { $0.name == "query" })?.value, "色 & C++")
        XCTAssertEqual(values.first(where: { $0.name == "folderId" })?.value, "folder-1")
        XCTAssertEqual(values.first(where: { $0.name == "cursor" })?.value, "a+b/c")
        XCTAssertTrue(path.contains("%2B"))
        XCTAssertEqual(LAADriveData.path(query: "", folderID: nil, cursor: nil), "/v1/drive/files")
        XCTAssertNil(LAADriveData.path(query: String(repeating: "🪴", count: 101), folderID: nil, cursor: nil))
    }

    func testProtectedMetadataFormatKeepsFlatItemsAndShortcutTargets() throws {
        let source = #"{"items":[{"id":"shortcut01","name":"Project","mimeType":"application/vnd.google-apps.shortcut","kind":"shortcut","version":"123","shortcut":{"targetId":"folder01","targetMimeType":"application/vnd.google-apps.folder","requiresResourceKey":false},"webViewLink":"https://drive.google.com/file/d/shortcut01/view","hasThumbnail":true}],"nextCursor":"opaque+cursor","incompleteSearch":false}"#
        let page = try JSONDecoder().decode(LAADriveListingPage.self, from: Data(source.utf8))
        let stored = try JSONDecoder().decode(LAADriveListingPage.self, from: JSONEncoder().encode(page))
        XCTAssertEqual(stored.items.first?.item.id, "shortcut01")
        XCTAssertEqual(stored.items.first?.version, "123")
        XCTAssertEqual(stored.items.first?.shortcut?.targetID(visited: []), "folder01")
        XCTAssertEqual(stored.items.first?.safeWebViewURL?.host, "drive.google.com")
        XCTAssertEqual(stored.nextCursor, "opaque+cursor")
    }

    func testFileTypeAndVideoDurationSurvivePaginationAndCaching() throws {
        let query = LAADriveBrowseQuery(section: .my, folderID: "folder01", cursor: "cursor", fileType: .video, order: .recent)
        let path = try XCTUnwrap(query.path)
        XCTAssertEqual(URLComponents(string: path)?.queryItems?.first { $0.name == "type" }?.value, "video")
        XCTAssertEqual(URLComponents(string: path)?.queryItems?.first { $0.name == "order" }?.value, "recent")
        let source = #"{"items":[{"id":"video01","name":"Video","kind":"file","mimeType":"video/mp4","durationSeconds":125.5}],"incompleteSearch":false}"#
        let page = try JSONDecoder().decode(LAADriveListingPage.self, from: Data(source.utf8))
        XCTAssertEqual(page.items.first?.durationSeconds, 125.5)
        XCTAssertEqual(try JSONDecoder().decode(LAADriveListingPage.self, from: JSONEncoder().encode(page)).items.first?.durationSeconds, 125.5)
    }

    func testFiltersUseServerKindAndMimeWithoutDroppingUnknownFiles() throws {
        let folder = try item("Projects", mime: "application/vnd.google-apps.folder", kind: "folder")
        let image = try item("Portrait", mime: "image/png", kind: "file")
        let unknown = try item("Unknown", mime: "application/octet-stream", kind: "file")
        XCTAssertTrue(LAADriveFilter.folders.contains(folder))
        XCTAssertFalse(LAADriveFilter.images.contains(folder))
        XCTAssertTrue(LAADriveFilter.images.contains(image))
        XCTAssertFalse(LAADriveFilter.documents.contains(unknown))
        XCTAssertTrue([folder, image, unknown].allSatisfy(LAADriveFilter.all.contains))
    }

    func testOfficeFilesAreEligibleForNativePreview() throws {
        for mime in ["application/msword", "application/vnd.ms-excel", "application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"] {
            let data = try JSONSerialization.data(withJSONObject: ["id": "office01", "name": "Office", "mimeType": mime, "kind": "file", "downloadable": true])
            let value = try JSONDecoder().decode(LAADriveItem.self, from: data)
            XCTAssertTrue(value.isDocument)
            XCTAssertNil(LAADrivePresentation.reason(value))
        }
    }

    func testMetadataAndUnsupportedReasonsUseOnlyReturnedValues() throws {
        let json = """
        {"id":"document01","name":"Doc","mimeType":"application/vnd.google-apps.document", "kind":"workspace_document", "size":null, "modifiedAt":"2026-10-25T13:00:00Z", "downloadable":false, "exportFormats":["application/pdf"]}
        """
        let document = try JSONDecoder().decode(LAADriveItem.self, from: Data(json.utf8))
        XCTAssertNil(document.size)
        XCTAssertNil(document.owners)
        XCTAssertNil(document.thumbnailLink)
        XCTAssertEqual(document.exportFormats, ["application/pdf"])
        XCTAssertEqual(LAADrivePresentation.reason(document), LAACopy.Drive.notDownloadable)
        let allowed = """
        {"id":"document01","name":"Doc","mimeType":"application/vnd.google-apps.document", "kind":"workspace_document", "downloadable":true, "exportFormats":["application/pdf"]}
        """
        XCTAssertNil(LAADrivePresentation.reason(try JSONDecoder().decode(LAADriveItem.self, from: Data(allowed.utf8))))
        let unknown = try item("unknown", mime: "application/octet-stream", kind: "file")
        XCTAssertEqual(LAADrivePresentation.reason(unknown), LAACopy.Drive.downloadUnknown)
    }
}
#endif
