#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAABrainTests: XCTestCase {
    private func file(_ path: String) throws -> LAABrainFile {
        let id = LAABrainReference(path: path, includeInbox: false).id
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "path": path, "title": path, "modifiedAt": "2026-10-29T00:00:00Z", "area": "default"])
        return try JSONDecoder().decode(LAABrainFile.self, from: data)
    }

    func testCreateUsesInboxAndSuffixAndRejectsUnsafeNamesAndLargeContent() throws {
        let request = try XCTUnwrap(LAABrainCreateBody.make(name: " 買い物.md ", content: "# 買い物\n"))
        XCTAssertEqual(request.path, "Inbox/買い物.md")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String])
        XCTAssertEqual(object["onConflict"], "suffix")
        XCTAssertNil(object["overwrite"])
        for name in ["", "../secret", ".hidden", "a:b", "a\\b", "a\nb"] {
            XCTAssertNil(LAABrainCreateBody.make(name: name, content: "x"), name)
        }
        XCTAssertNil(LAABrainCreateBody.make(name: "large", content: String(repeating: "a", count: 48 * 1024 + 1)))
    }

    func testFoldersAndPathResolutionDoNotGuessAmbiguousNames() throws {
        let files = try ["Company/Note.md", "Guide/Note.md", "Company/Sub/Other.md"].map(file)
        XCTAssertEqual(LAABrainPaths.folders(in: files, parent: ""), ["Company", "Guide"])
        XCTAssertEqual(LAABrainPaths.folders(in: files, parent: "Company"), ["Sub"])
        XCTAssertEqual(LAABrainPaths.resolve("Note#part|title", currentPath: "Company/Start.md", files: files)?.path, "Company/Note.md")
        XCTAssertEqual(LAABrainPaths.resolve("../Guide/Note.md", currentPath: "Company/Start.md", files: files)?.path, "Guide/Note.md")
        XCTAssertNil(LAABrainPaths.resolve("Note", currentPath: "Elsewhere/Start.md", files: files))
        XCTAssertNil(LAABrainPaths.resolve("../../outside", currentPath: "Company/Start.md", files: files))
    }

    func testDocumentKeepsFrontmatterUnknownSyntaxAndImages() throws {
        let source = "---\nstatus: 草案\n---\n# Heading\n\n::: strange\n![map](../Assets/map.png)\n[[Other|次へ]]\n`[[Other]]`\n"
        let doc = LAABrainDocument(source)
        XCTAssertEqual(doc.frontmatter, "---\nstatus: 草案\n---")
        let parts = doc.parts(currentPath: "Company/Start.md", files: [try file("Company/Other.md")])
        XCTAssertTrue(parts.contains(.raw("::: strange")))
        XCTAssertTrue(parts.contains(.image("![map](../Assets/map.png)")))
        let rendered = parts.compactMap { if case .markdown(let text) = $0 { return text }; return nil }.joined(separator: "\n")
        XCTAssertTrue(rendered.contains("[次へ](laabrain://note/"))
        XCTAssertTrue(rendered.contains("`[[Other]]`"))
        XCTAssertEqual(LAABrainDocument("---\nunfinished").body, "---\nunfinished")
        XCTAssertNil(LAABrainDocument("---\nunfinished").frontmatter)
    }

    func testLongCodeFenceIsNotMistakenForAClosingFence() {
        let doc = LAABrainDocument("````\n```\n![not-an-image](a.png)\n````\n")
        let parts = doc.parts(currentPath: "Start.md", files: [])
        XCTAssertFalse(parts.contains { if case .image = $0 { return true }; return false })
    }

    func testInlineCodeDoesNotResolveWikisOrEmbeds() throws {
        let source = "`![[Other]]` and ``[[Other]] ![x](image.png)`` and [[Other]]"
        let parts = LAABrainDocument(source).parts(currentPath: "Company/Start.md", files: [try file("Company/Other.md")])
        XCTAssertFalse(parts.contains { if case .image = $0 { return true }; return false })
        let text = parts.compactMap { if case .markdown(let value) = $0 { return value }; return nil }.joined()
        XCTAssertTrue(text.contains("`![[Other]]`"))
        XCTAssertTrue(text.contains("``[[Other]] ![x](image.png)``"))
        XCTAssertTrue(text.contains("[Other](laabrain://note/"))
    }

    func testURLAndFileIdUsePercentEncodingAndNFC() throws {
        let route = try XCTUnwrap(LAABrainPaths.request("/v1/brain/search", items: [URLQueryItem(name: "q", value: "色 & 形 C++")], includeInbox: true))
        let components = try XCTUnwrap(URLComponents(string: route))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, "色 & 形 C++")
        XCTAssertTrue(route.contains("C%2B%2B"))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "area" })?.value, "inbox")
        XCTAssertEqual(LAABrainReference(path: "é.md", includeInbox: false).id,
                       LAABrainReference(path: "e\u{301}.md", includeInbox: false).id)
    }

    func testHeadingsFootnotesHighlightsAndMultipleEmbedsKeepTheirSource() throws {
        let source = "---\nstatus: draft\n---\n# 見出し\n[[Other#詳細|次へ]] と [^注]\n==強調==\n前 ![[Other#詳細]] 間 ![図](../Assets/図.png) 後\n[^注]: 脚注の本文\n## 詳細\n本文\n# 続き\n"
        let document = LAABrainDocument(source)
        let files = try ["Company/Start.md", "Company/Other.md"].map(file)
        let parts = document.parts(currentPath: "Company/Start.md", files: files)
        XCTAssertEqual(document.properties.first?.name, "status")
        XCTAssertEqual(document.properties.first?.value, "draft")
        XCTAssertTrue(parts.contains(.heading(source: "# 見出し", title: "見出し")))
        XCTAssertTrue(parts.contains(.highlight("==強調==")))
        XCTAssertTrue(parts.contains(.image("![[Other#詳細]]")))
        XCTAssertTrue(parts.contains(.image("![図](../Assets/図.png)")))
        XCTAssertTrue(parts.contains(.footnote(id: "注", text: "脚注の本文")))
        let rendered = parts.compactMap { if case .markdown(let text) = $0 { return text }; return nil }.joined(separator: "\n")
        XCTAssertTrue(rendered.contains("laabrain://note/"))
        XCTAssertTrue(rendered.contains("laabrain://footnote/"))
        XCTAssertTrue(rendered.contains("前 "))
        XCTAssertTrue(rendered.contains(" 間 "))
        XCTAssertTrue(rendered.contains(" 後"))
        XCTAssertEqual(document.section("詳細"), "## 詳細\n本文")
        XCTAssertEqual(LAABrainEmbedSpec.parse("![[Other#詳細|別名]]")?.anchor, "詳細")
        XCTAssertEqual(LAABrainPaths.resolve("#見出し", currentPath: "Company/Start.md", files: files)?.path, "Company/Start.md")
    }

    func testSyncConflictNamesPointToOriginal() throws {
        let conflict = try file("Folder/Note.sync-conflict-20261101-123456-ABCD123.md")
        XCTAssertEqual(conflict.conflictOriginalPath, "Folder/Note.md")
        XCTAssertNil(try file("Folder/Note.md").conflictOriginalPath)
    }
}
#endif
