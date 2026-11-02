#if LAA_BUILD
import SwiftUI
import ImageIO
import PDFKit
import UIKit

/// Presentation never mutates the Markdown source; unresolved content keeps its source visible.
struct LAABrainRenderedDocument: View {
    let note: LAABrainNote
    let files: [LAABrainFile]
    @ObservedObject var local: LAABrainLocalVault
    let isLocal: Bool
    let visited: Set<String>
    let depth: Int
    let open: (LAABrainReference) -> Void

    var body: some View {
        let document = LAABrainDocument(note.text)
        let parts = document.parts(currentPath: note.path, files: files)
        if let frontmatter = document.frontmatter {
            DisclosureGroup {
                ForEach(Array(document.properties.enumerated()), id: \.offset) { _, property in
                    HStack(alignment: .top) {
                        Text(verbatim: property.name).fontWeight(.semibold)
                        Spacer(minLength: LAASpacing.x3)
                        Text(verbatim: property.value).textSelection(.enabled)
                    }.laaTextStyle(.secondary)
                }
                Text(verbatim: frontmatter).laaTextStyle(.secondary).monospaced()
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } label: { Text(verbatim: LAACopy.Brain.frontmatter) }
        }
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
            switch part {
            case .markdown(let source):
                MarkdownText(source: source)
            case .raw(let source):
                Text(verbatim: source).laaTextStyle(.body).monospaced()
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            case .heading(let source, let title):
                if title.contains("==") {
                    LAABrainHighlight(source: title, heading: true).id(LAABrainDocument.anchorID(path: note.path, title: title))
                } else {
                    MarkdownText(source: source).id(LAABrainDocument.anchorID(path: note.path, title: title))
                }
            case .footnote(let id, let text):
                HStack(alignment: .top, spacing: LAASpacing.x2) {
                    Text(verbatim: "[\(id)]").laaTextStyle(.secondary)
                    MarkdownText(source: text)
                }.id(LAABrainDocument.footnoteID(path: note.path, id: id))
            case .highlight(let source):
                LAABrainHighlight(source: source)
            case .image(let source):
                LAABrainEmbedView(source: source, currentPath: note.path, files: files, local: local,
                                  isLocal: isLocal, visited: visited, depth: depth, maxPixelSize: 1600, open: open)
            }
        }
        let gallery = parts.compactMap { part -> String? in
            guard case .image(let source) = part, let spec = LAABrainEmbedSpec.parse(source) else { return nil }
            let name = spec.target.split(separator: "#").first.map(String.init) ?? ""
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            return ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp"].contains(ext) ? source : nil
        }
        if isLocal && depth == 0 && !gallery.isEmpty {
            DisclosureGroup("Gallery") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: LAASpacing.x2) {
                    ForEach(Array(gallery.enumerated()), id: \.offset) { _, source in
                        LAABrainEmbedView(source: source, currentPath: note.path, files: files, local: local,
                                          isLocal: true, visited: visited, depth: depth, maxPixelSize: 512, open: open)
                            .frame(maxHeight: 160).clipped()
                    }
                }
            }
        }
    }
}

/// Reuses the same attachment policy and renderer as the note, so thumbnail
/// browsing cannot read a different part of the selected vault.
struct LAABrainGalleryView: View {
    let index: LAABrainIndex
    let files: [LAABrainFile]
    @ObservedObject var local: LAABrainLocalVault
    let open: (LAABrainReference) -> Void

    private var items: [(file: LAABrainFile, source: String)] {
        index.entries.compactMap { entry in
            let images = LAABrainDocument(entry.text).parts(currentPath: entry.file.path, files: files)
            for part in images {
                guard case .image(let source) = part, let spec = LAABrainEmbedSpec.parse(source) else { continue }
                let name = spec.target.split(separator: "#").first.map(String.init) ?? ""
                if ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) {
                    return (entry.file, source)
                }
            }
            return nil
        }
    }

    var body: some View {
        if items.isEmpty {
            Text(verbatim: "画像を含むノートはありません。").foregroundStyle(LAAColor.secondaryText)
        } else {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: LAASpacing.x3) {
                ForEach(items, id: \.file.id) { item in
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        LAABrainEmbedView(source: item.source, currentPath: item.file.path, files: files, local: local,
                                          isLocal: true, visited: [item.file.path], depth: 0, maxPixelSize: 512, open: open)
                            .frame(height: 150).clipped()
                        Button { open(LAABrainReference(file: item.file, includeInbox: true)) } label: {
                            Text(verbatim: item.file.title).lineLimit(2)
                        }.accessibilityIdentifier("laa.brain.gallery.note")
                    }
                    .padding(LAASpacing.x3).background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                }
            }
        }
    }
}

private struct LAABrainHighlight: View {
    let source: String
    var heading = false

    private var prefix: (symbol: String?, text: String) {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        for (marker, symbol) in [("- [ ] ", "☐"), ("- [x] ", "☑"), ("- [X] ", "☑"),
                                 ("- ", "•"), ("* ", "•"), ("+ ", "•"), ("> ", "▏")] {
            if trimmed.hasPrefix(marker) { return (symbol, String(trimmed.dropFirst(marker.count))) }
        }
        if let range = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return (String(trimmed[range]).trimmingCharacters(in: .whitespaces), String(trimmed[range.upperBound...]))
        }
        return (nil, source)
    }

    var body: some View {
        HStack(alignment: .top, spacing: LAASpacing.x2) {
            if let symbol = prefix.symbol { Text(verbatim: symbol).foregroundStyle(LAAColor.secondaryText) }
            Text(attributed).laaTextStyle(.body).font(heading ? .title2.bold() : nil).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var attributed: AttributedString {
        let pattern = #"==([^=\n]+)=="#
        let text = prefix.text
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return AttributedString(text) }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var output = AttributedString()
        var position = text.startIndex
        func fragment(_ text: String) -> AttributedString {
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        }
        for match in matches {
            guard let whole = Range(match.range(at: 0), in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
            output += fragment(String(text[position..<whole.lowerBound]))
            var marked = fragment(String(text[inner]))
            marked.backgroundColor = Color.yellow.opacity(0.35)
            output += marked
            position = whole.upperBound
        }
        output += fragment(String(text[position...]))
        return output
    }
}

private struct LAABrainEmbedView: View {
    private struct LoadKey: Equatable { let source: String; let path: String; let revision: Int; let isLocal: Bool }
    @EnvironmentObject private var bridge: LAABridgeSession
    let source: String
    let currentPath: String
    let files: [LAABrainFile]
    @ObservedObject var local: LAABrainLocalVault
    let isLocal: Bool
    let visited: Set<String>
    let depth: Int
    let maxPixelSize: Int
    let open: (LAABrainReference) -> Void
    @State private var content: Content?

    private enum Content {
        case note(LAABrainNote, LAABrainFile, String?)
        case image(UIImage)
        case pdf(Data)
        case unavailable(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            if let spec = LAABrainEmbedSpec.parse(source), spec.hasSurroundingText {
                Text(verbatim: source).laaTextStyle(.secondary).textSelection(.enabled)
            }
            switch content {
            case .none:
                ProgressView().accessibilityLabel(Text(verbatim: "Loading attachment"))
            case .note(let note, let file, let anchor):
                VStack(alignment: .leading, spacing: LAASpacing.x3) {
                    Button { open(LAABrainReference(file: file, includeInbox: true, anchor: anchor)) } label: {
                        Label { Text(verbatim: file.path) } icon: { Image(systemName: "doc.text") }
                    }
                    LAABrainRenderedDocument(note: note, files: files, local: local, isLocal: isLocal,
                                             visited: visited.union([file.path]), depth: depth + 1, open: open)
                }.padding(LAASpacing.x3).background(LAAColor.subtleSurface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            case .image(let image):
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    .accessibilityLabel(Text(verbatim: LAABrainEmbedSpec.parse(source)?.target ?? "Image"))
                    .accessibilityIdentifier("laa.brain.embed.image")
            case .pdf(let data):
                LAABrainPDF(data: data).id(data).frame(height: 360)
                    .accessibilityLabel(Text(verbatim: LAABrainEmbedSpec.parse(source)?.target ?? "PDF"))
            case .unavailable(let message):
                Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                if !(LAABrainEmbedSpec.parse(source)?.hasSurroundingText ?? false) {
                    Text(verbatim: source).laaTextStyle(.secondary).monospaced().textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: LoadKey(source: source, path: currentPath, revision: isLocal ? local.revision : 0, isLocal: isLocal)) { await load() }
    }

    @MainActor private func load() async {
        content = nil
        guard let spec = LAABrainEmbedSpec.parse(source) else { content = .unavailable("Unsupported embed."); return }
        let name = spec.target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp"]
        if !imageTypes.contains(ext), ext != "pdf",
           let file = LAABrainPaths.resolve(spec.target, currentPath: currentPath, files: files) {
            guard depth < 3, !visited.contains(file.path) else { content = .unavailable("Nested or circular embed. Open the note directly."); return }
            do {
                let note: LAABrainNote
                if isLocal {
                    let root = try local.snapshot()
                    note = try await Task.detached(priority: .userInitiated) { try LAABrainVaultIO.note(root: root, path: file.path) }.value
                } else {
                    guard let route = LAABrainPaths.request("/v1/brain/files/" + file.id) else { throw LAABridgeError.invalidResponse }
                    note = try await LAABrainData.read(route, bridge: bridge)
                }
                try Task.checkCancellation()
                if let anchor = spec.anchor, !anchor.isEmpty {
                    guard let section = LAABrainDocument(note.text).section(anchor) else { content = .unavailable("Embedded heading not found."); return }
                    content = .note(LAABrainNote(id: note.id, path: note.path, text: section), file, anchor)
                } else { content = .note(note, file, nil) }
            } catch is CancellationError { return }
            catch { content = .unavailable(LAABrainVaultError.unreadable.message) }
            return
        }
        guard imageTypes.contains(ext) || ext == "pdf" else { content = .unavailable("This embed is unavailable."); return }
        guard isLocal else { content = .unavailable("Attachments are unavailable over the Mac connection."); return }
        do {
            let root = try local.snapshot()
            let attachment = try await Task.detached(priority: .userInitiated) {
                try LAABrainVaultIO.attachment(root: root, currentPath: currentPath, target: spec.target)
            }.value
            try Task.checkCancellation()
            if ext == "pdf" {
                guard PDFDocument(data: attachment.data) != nil else { content = .unavailable("This PDF could not be opened."); return }
                content = .pdf(attachment.data)
            } else {
                guard let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                      ] as CFDictionary) else { content = .unavailable("This image could not be opened."); return }
                content = .image(UIImage(cgImage: image))
            }
        } catch is CancellationError { return }
        catch { content = .unavailable((error as? LAABrainVaultError)?.message ?? LAABrainVaultError.unreadable.message) }
    }
}

private struct LAABrainPDF: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.document = PDFDocument(data: data); return view
    }
    func updateUIView(_ view: PDFView, context: Context) { }
}
#endif
