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
}
#endif
