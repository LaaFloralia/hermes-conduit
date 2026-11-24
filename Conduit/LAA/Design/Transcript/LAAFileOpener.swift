#if LAA_BUILD
import SwiftUI

/// A text file read through an existing route, shown in the app: Markdown as
/// a document, code with its line numbers, opened at the line named.
struct LAAFileDocumentSheet: View, Identifiable {
    let id = UUID()
    let name: String
    let text: String
    let reference: LAAFileReference
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if reference.kind == .markdown {
                    ScrollView {
                        MarkdownText(source: text, foregroundStyle: LAAColor.text)
                            .environment(\.chatTextSize, LAAReadingStyle.reading(ChatTextAppearance(size: ChatTypography.stored())))
                            .frame(maxWidth: LAATranscriptMetrics.proseMeasure ?? .infinity, alignment: .leading)
                            .padding(LAASpacing.horizontal)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    LAACodeFileView(text: text, line: reference.line)
                }
            }
            .background(LAAColor.background)
            .navigationTitle(Text(verbatim: reference.label))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "閉じる") }
                        .accessibilityIdentifier("laa.file.close")
                }
            }
        }
        .laaSheetSize(.page)
        .accessibilityIdentifier("laa.file.document")
    }

    /// The text of a `data:` URL, when it is UTF-8.
    static func text(fromDataURL value: String) -> String? {
        guard let comma = value.firstIndex(of: ","), value[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Code with its line numbers, 13/20 mono on the wash; the named line is
/// marked and scrolled to.
struct LAACodeFileView: View {
    let text: String
    let line: Int?
    private static let maxLines = 20_000

    var body: some View {
        let lines = Array(text.components(separatedBy: "\n").prefix(Self.maxLines))
        let digits = String(lines.count).count
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, value in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: String(index + 1).leftPadded(to: digits))
                                .foregroundStyle(LAAColor.secondaryText)
                            Text(verbatim: value.isEmpty ? " " : value)
                                .foregroundStyle(LAAColor.text)
                                .fixedSize()
                        }
                        .font(.system(size: 13 * LAAReadingStyle.platformScale, design: .monospaced))
                        .frame(minHeight: 20 * LAAReadingStyle.platformScale, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(index + 1 == line ? LAAColor.subtleSurface : Color.clear)
                        .id(index + 1)
                    }
                }
                .padding(.vertical, 12)
            }
            .textSelection(.enabled)
            .onAppear {
                guard let line else { return }
                DispatchQueue.main.async { proxy.scrollTo(line, anchor: .center) }
            }
        }
        .accessibilityIdentifier("laa.file.code")
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

/// A Drive file named in a reply, in the app's own Drive viewer.
struct LAADriveLinkSheet: View, Identifiable {
    let fileID: String
    var id: String { fileID }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LAADriveDetailView(item: LAADriveItem(id: fileID, name: "Google Drive", mimeType: "", kind: "file",
                                                  version: nil, size: nil, modifiedAt: nil, downloadable: nil,
                                                  exportFormats: nil, thumbnailLink: nil, owners: nil))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: { Text(verbatim: "閉じる") }
                    }
                }
        }
        .laaSheetSize(.page)
    }
}

/// Chat: a Drive link a reply names opens in the app's Drive viewer, not in
/// Safari or the Drive app. Every other link goes where it went.
struct LAADriveLinkOpener: ViewModifier {
    @Environment(\.openURL) private var outerOpenURL
    @State private var drive: LAADriveLinkSheet?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                if let id = LAAFileLinks.driveID(url) {
                    drive = LAADriveLinkSheet(fileID: id)
                } else {
                    outerOpenURL(url)
                }
                return .handled
            })
            .sheet(item: $drive) { $0 }
    }
}
#endif
