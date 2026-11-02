#if LAA_BUILD
import XCTest
@testable import Conduit

/// The index's link rows and a single link resolution must not rescan every
/// file: a Brain folder of ten thousand notes froze the owner's iPhone in
/// `LAABrainIndex.backlinks` (watchdog SIGKILL, 2026-11-03). These tests keep
/// the previous implementation as the oracle and as the "before" measurement.
final class LAABrainIndexPerformanceTests: XCTestCase {
    private func file(_ path: String) -> LAABrainFile {
        LAABrainFile(id: LAABrainReference(path: path, includeInbox: true).id, path: path,
                     title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                     modifiedAt: "", area: "local", unreadable: nil)
    }

    /// `count` notes in 40 folders. Each note links to the next two notes by
    /// their unique file name and to one note by its root-relative path.
    private func fixture(count: Int) -> (files: [LAABrainFile], texts: [String: String]) {
        var files: [LAABrainFile] = []
        var texts: [String: String] = [:]
        for index in 0..<count {
            let folder = "F\(index % 40)"
            let path = "\(folder)/Note \(index).md"
            files.append(file(path))
            let first = (index + 1) % count
            let second = (index + 7) % count
            let target = "F\(first % 40)/Note \(first).md"
            let image = index % 50 == 0 ? "\n![[photo \(index).png]]" : ""
            texts[path] = "# Note \(index)\n\n本文 \(index) 行\n[[Note \(first)]] と [[Note \(second)|別名]] と [[\(target)#見出し]]\(image)\n"
        }
        return (files, texts)
    }

    private func read(_ texts: [String: String]) -> (String) throws -> String {
        { path in
            guard let text = texts[path] else { throw NSError(domain: "fixture", code: 1) }
            return text
        }
    }

    // MARK: - The implementation before this change, kept as the oracle.

    private func legacyResolve(_ target: String, currentPath: String, files: [LAABrainFile]) -> LAABrainFile? {
        let targetPath = target.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let reference = targetPath
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines).removingPercentEncoding ?? ""
        if reference.isEmpty, targetPath.contains("#") { return files.first { $0.path == currentPath } }
        guard !reference.isEmpty, !reference.hasPrefix("/"), !reference.contains(":") else { return nil }
        let named = reference.lowercased().hasSuffix(".md") ? reference : reference + ".md"
        func normalized(_ raw: String) -> String? {
            var components: [String] = []
            for part in raw.split(separator: "/", omittingEmptySubsequences: false) {
                if part == "." { continue }
                if part == ".." { guard !components.isEmpty else { return nil }; components.removeLast() }
                else if part.isEmpty { return nil }
                else { components.append(String(part)) }
            }
            return components.joined(separator: "/").precomposedStringWithCanonicalMapping
        }
        let directory = currentPath.split(separator: "/").dropLast().joined(separator: "/")
        let relative = normalized(directory.isEmpty ? named : directory + "/" + named)
        let absolute = normalized(named)
        if let exact = files.first(where: { $0.path.precomposedStringWithCanonicalMapping == relative }) { return exact }
        if let exact = files.first(where: { $0.path.precomposedStringWithCanonicalMapping == absolute }) { return exact }
        guard !named.contains("/") else { return nil }
        let matches = files.filter { $0.path.split(separator: "/").last.map(String.init) == named }
        return matches.count == 1 ? matches[0] : nil
    }

    private func legacyBacklinks(_ index: LAABrainIndex, to path: String, files: [LAABrainFile]) -> [LAABrainFile] {
        var seen = Set<String>()
        let result = index.entries.compactMap { entry -> LAABrainFile? in
            guard entry.file.path != path,
                  entry.wikiTargets.contains(where: { legacyResolve($0, currentPath: entry.file.path, files: files)?.path == path })
            else { return nil }
            return entry.file
        }
        return result.filter { seen.insert($0.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func duration(_ work: () -> Void) -> TimeInterval {
        var elapsed: TimeInterval = 0
        let started = Date()
        work()
        elapsed = Date().timeIntervalSince(started)
        return elapsed
    }

    // MARK: - Equivalence with the previous rules.

    func testResolveKeepsEveryRuleOfThePreviousImplementation() {
        let files = [
            file("A/Start.md"), file("A/Other.md"), file("B/Other.md"),
            file("Café.md"),                       // NFC on disk
            file("Caf\u{0065}\u{0301}/Nested.md"), // NFD folder on disk
            file("Root Only.md"), file("日本 語.md"),
        ]
        let targets = ["Other", "Other.md", "A/Other", "/A/Other", "../Other", "..", "./Other", "B/Other.md",
                       "Other|alias", "Other#見出し", "#見出し", "#", "", "http:Other", "Missing", "Café",
                       "Caf\u{0065}\u{0301}", "%E6%97%A5%E6%9C%AC%20%E8%AA%9E", "日本 語", "Root Only",
                       "Nested", "A//Other", "A/./Other", "A/../A/Other"]
        for target in targets {
            for currentPath in ["A/Start.md", "B/Other.md", "Start.md"] {
                XCTAssertEqual(LAABrainPaths.resolve(target, currentPath: currentPath, files: files)?.path,
                               legacyResolve(target, currentPath: currentPath, files: files)?.path,
                               "resolve(\"\(target)\") from \(currentPath)")
            }
        }
    }

    func testOutgoingAndBacklinksKeepPreviousResults() throws {
        let files = [file("A/Start.md"), file("A/Other.md"), file("B/Other.md"), file("Root.md")]
        let texts = ["A/Start.md": "[[Other]] [[Root]] [[Missing]]",
                     "A/Other.md": "[[Start#見出し]] [[Other]]",
                     "B/Other.md": "[[Other]]",
                     "Root.md": "[[B/Other]]"]
        let index = LAABrainIndex(files: files, read: read(texts))
        let links = index.entries.flatMap { entry in
            entry.wikiTargets.compactMap { legacyResolve($0, currentPath: entry.file.path, files: files)?.path }
        }
        for path in files.map(\.path) {
            XCTAssertEqual(index.backlinks(to: path, files: files).map(\.path),
                           legacyBacklinks(index, to: path, files: files).map(\.path), path)
        }
        XCTAssertEqual(index.outgoing(from: "A/Start.md", files: files).map(\.path), ["A/Other.md", "Root.md"])
        XCTAssertFalse(links.isEmpty)
    }

    // MARK: - The gallery's rows come from the same parser.

    /// The gallery filters notes by a substring before parsing. Every way the
    /// parser produces an image must survive that filter, and nothing else may
    /// become a row.
    func testGalleryRowsMatchTheNoteParserForEveryImageForm() throws {
        let files = ["A/Wiki.md", "A/Markdown.md", "A/Fence.md", "A/Inline.md", "A/Plain.md",
                     "A/Heading.md", "A/Footnote.md", "A/Two.md", "A/Pdf.md"].map(file)
        let texts = [
            "A/Wiki.md": "本文\n![[photo.png]]",
            "A/Markdown.md": "本文\n![alt text](photo.jpg)",
            "A/Fence.md": "本文\n```\n![[hidden.png]]\n```\n",
            "A/Inline.md": "本文 `![[inline.png]]` だけ",
            "A/Plain.md": "画像のないノート [[Wiki]]",
            "A/Heading.md": "# 見出し\n![[after-heading.heic]]",
            "A/Footnote.md": "本文[^1]\n\n[^1]: ![[note.gif]]",
            "A/Two.md": "![[first.webp]]\n![[second.tiff]]",
            "A/Pdf.md": "![[manual.pdf]]",
        ]
        let index = LAABrainIndex(files: files, read: read(texts))
        let legacy = files.compactMap { entry -> (file: LAABrainFile, source: String)? in
            let images = LAABrainDocument(texts[entry.path] ?? "").parts(currentPath: entry.path, files: files)
            for part in images {
                guard case .image(let source) = part, let spec = LAABrainEmbedSpec.parse(source) else { continue }
                let name = spec.target.split(separator: "#").first.map(String.init) ?? ""
                if ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) {
                    return (entry, source)
                }
            }
            return nil
        }
        let rows = LAABrainGalleryRows.items(index: index, files: files)
        XCTAssertEqual(rows.map(\.file.path), legacy.map(\.file.path))
        XCTAssertEqual(rows.map(\.source), legacy.map(\.source))
        // A footnote's image stays footnote text and a fenced or inline-code
        // embed is not an image; the parser says so, and the filter agrees.
        XCTAssertEqual(rows.map(\.file.path), ["A/Wiki.md", "A/Markdown.md", "A/Heading.md", "A/Two.md"])
    }

    // MARK: - The hang that took the app down.

    func testBacklinksOverAThousandNotesDoesNotRescanEveryFile() throws {
        let small = 500
        let (files, texts) = fixture(count: small)
        let index = LAABrainIndex(files: files, read: read(texts))
        let target = "F0/Note 0.md"
        XCTAssertEqual(index.backlinks(to: target, files: files).count,
                       legacyBacklinks(index, to: target, files: files).count)

        let legacy = duration { _ = legacyBacklinks(index, to: target, files: files) }
        let current = duration { _ = index.backlinks(to: target, files: files) }
        print("backlinks \(small) notes: previous \(String(format: "%.3f", legacy))s, now \(String(format: "%.4f", current))s")
        XCTAssertLessThan(current, legacy / 10, "backlinks still rescans every file")
    }

    func testTenThousandNotesRenderTheirLinksQuickly() throws {
        let large = 10_000
        let (files, texts) = fixture(count: large)
        let built = duration { _ = LAABrainIndex(files: files, read: read(texts)) }
        let index = LAABrainIndex(files: files, read: read(texts))
        let note = "F0/Note 0.md"
        let backlinks = duration { _ = index.backlinks(to: note, files: files) }
        let outgoing = duration { _ = index.outgoing(from: note, files: files) }
        // One lookup per rendered note, as `LAABrainDocument.parts` builds it,
        // then one hit per link: the screen must not pay a pass per link.
        let lookup = LAABrainPathLookup(files: files)
        let resolved = duration {
            for entry in index.entries.prefix(500) {
                for target in entry.wikiTargets { _ = lookup.resolve(target, currentPath: entry.file.path) }
            }
        }
        // The render entry point itself, on a note with 200 links.
        let manyLinks = (0..<200).map { "[[Note \($0)]]" }.joined(separator: "\n")
        var parts: [LAABrainDocument.Part] = []
        let rendered = duration { parts = LAABrainDocument(manyLinks).parts(currentPath: note, files: files) }
        // The single-shot entry point is one pass over the file list per call;
        // 1,500 such calls took 16.404 s on the simulator (candidate log,
        // 2026-11-03). A redraw does not use it, so this is measured and
        // printed for the record, not asserted.
        let singleStart = Date()
        for number in 0..<40 { _ = LAABrainPaths.resolve("Note \(number)", currentPath: note, files: files) }
        let single = Date().timeIntervalSince(singleStart) / 40
        print("10k notes: build \(String(format: "%.3f", built))s, backlinks \(String(format: "%.4f", backlinks))s, "
              + "outgoing \(String(format: "%.4f", outgoing))s, 1500 lookups \(String(format: "%.4f", resolved))s, "
              + "render 200 links \(String(format: "%.4f", rendered))s, "
              + "single-shot \(String(format: "%.1f", single * 1000))ms/call")
        XCTAssertLessThan(backlinks, 0.05)
        XCTAssertLessThan(outgoing, 0.05)
        XCTAssertLessThan(resolved, 1.0)
        XCTAssertLessThan(rendered, 1.0, "rendering rescans the file list per link")
        // Every link points where the previous implementation pointed it, with
        // the label it had: the note screen renders real links, not a no-op.
        let markdown = parts.compactMap { part -> String? in
            if case .markdown(let text) = part { return text }
            return nil
        }.joined()
        // The screen the owner opens next: every note of the same folder.
        var rows: [(file: LAABrainFile, source: String)] = []
        let gallery = duration { rows = LAABrainGalleryRows.items(index: index, files: files) }
        print("gallery rows for \(files.count) notes: \(String(format: "%.4f", gallery))s, \(rows.count) rows")
        XCTAssertEqual(rows.count, files.count / 50, "the gallery lost or invented rows")
        XCTAssertLessThan(gallery, 5.0, "the gallery walks the whole folder per note")
        XCTAssertEqual(markdown.components(separatedBy: "laabrain://note/").count - 1, 200, "links were not rewritten")
        for number in 0..<200 {
            let target = "Note \(number)"
            guard let file = legacyResolve(target, currentPath: note, files: files) else {
                return XCTFail("fixture link \(target) does not resolve")
            }
            XCTAssertTrue(markdown.contains("[\(target)](laabrain://note/\(file.id))"),
                          "link \(target) does not point at \(file.path)")
        }
        XCTAssertEqual(index.backlinks(to: note, files: files), legacyBacklinks(index, to: note, files: files))
    }
}
#endif
