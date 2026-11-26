#if LAA_BUILD
import SwiftUI
import UIKit

// MARK: - Progress while the turn runs

/// The one line at the end of a running session (owner, 2026-11-12): what the
/// provider is doing in a word, in place of the tool traffic: "Compacting..."
/// or "thinking...". The words are English, as the owner chose. Fixed
/// height, so the transcript above never jumps when it changes; Reduce
/// Motion keeps the orb still.
struct LAAWorkProgressLine: View {
    let compacting: Bool

    static var height: CGFloat { LAATranscriptMetrics.thoughtMinHeight }

    var body: some View {
        // The shared thinking row (LAAThoughtLine), as in Chat.
        LAAThoughtLine(text: compacting ? "Compacting..." : "thinking...")
            .padding(.top, LAATranscriptMetrics.turnGap - LAATranscriptMetrics.rowGap)
            .accessibilityIdentifier(compacting ? "work.session.progress.compacting" : "work.session.progress.thinking")
    }
}

// MARK: - Request and running model

/// "▲ 依頼 Fable 5.2 → 実行 Opus 4.8", and when the Bridge saw the switch.
/// The plum stays on the triangle, as the house mark for "check this".
struct LAAWorkMismatchLine: View {
    let mismatch: LAAWorkSessionStyle.Mismatch

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
            Image(systemName: "triangle.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(LAAColor.attention)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                (Text(verbatim: "依頼 ").foregroundColor(LAAColor.secondaryText)
                 + Text(verbatim: mismatch.requested).foregroundColor(LAAColor.text)
                 + Text(verbatim: "  →  ").foregroundColor(LAAColor.secondaryText)
                 + Text(verbatim: "実行 ").foregroundColor(LAAColor.secondaryText)
                 + Text(verbatim: mismatch.running).foregroundColor(LAAColor.text).fontWeight(.semibold))
                    .laaTextStyle(.secondary)
                Text(verbatim: mismatch.seen ?? "依頼と違うモデル・推論で動いています")
                    .laaTextStyle(.note)
                    .foregroundStyle(LAAColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sent, not yet in the conversation

/// A follow-up this device sent, shown until Paseo's history has it. The
/// Bridge holds a follow-up while a turn runs, and only then hands it over.
struct LAAWorkSentEcho: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let attachments: [Attachment]
    /// The newest message the conversation showed when this was sent: only an
    /// owner's message after it can be this one. An ID, not a count: the page
    /// holds only the latest messages, so its length stays the same while the
    /// conversation grows, and an older page loaded above changes it.
    let after: String?
    let sentAt = Date()

    /// The echoes the conversation does not show yet. An owner's message newer
    /// than the echo is the message itself: the one with the same text first,
    /// else the oldest one not yet matched (the Bridge may have reworded it).
    static func pending(_ echoes: [LAAWorkSentEcho], in messages: [LAAWorkConversationMessage]) -> [LAAWorkSentEcho] {
        var claimed = Set<String>()
        var matched = Set<UUID>()
        func candidates(_ echo: LAAWorkSentEcho) -> [LAAWorkConversationMessage] {
            // A message the page no longer holds is older than everything on it.
            let newer = echo.after.flatMap { id in messages.lastIndex { $0.id == id } }
                .map { messages[($0 + 1)...] } ?? messages[...]
            return newer.filter { $0.role == "user" && !claimed.contains($0.id) }
        }
        // Same text first, for every echo; only then the oldest leftover.
        for echo in echoes {
            let trimmed = echo.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = candidates(echo).first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }) {
                claimed.insert(match.id); matched.insert(echo.id)
            }
        }
        return echoes.filter { echo in
            if matched.contains(echo.id) { return false }
            if let match = candidates(echo).first { claimed.insert(match.id); return false }
            // A day-old echo is not waiting for anything any more.
            return Date().timeIntervalSince(echo.sentAt) < 86_400
        }
    }
}

/// The owner's bubble for an echo, as the transcript draws it, with its own
/// pictures from this device and one quiet line under it.
struct LAAWorkSentEchoRow: View {
    let echo: LAAWorkSentEcho
    let queued: Bool
    @State private var preview: LAAWorkImagePreview.Request?

    var body: some View {
        LAATranscriptOwnerTurn(continues: false) {
            VStack(alignment: .trailing, spacing: 4) {
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    if !echo.text.isEmpty {
                        Text(verbatim: echo.text)
                            .font(.laaReading())
                            .foregroundStyle(LAAColor.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let images = echo.attachments.compactMap(LAAWorkAttachmentImage.image)
                    if !images.isEmpty {
                        HStack(spacing: LAASpacing.x2) {
                            ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                                Button { preview = .init(images: images, index: index) } label: {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 96, height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: "添付画像 \(index + 1)を開く"))
                                .accessibilityIdentifier("work.session.echo.image")
                            }
                        }
                    }
                }
                .laaTranscriptOwnerBubble()
                .opacity(0.86)
                Label { Text(verbatim: queued ? "順番待ち・この手番の後に届けます" : "送信済み・会話への反映を確認中") }
                    icon: { Image(systemName: queued ? "clock" : "checkmark") }
                    .laaTextStyle(.note)
                    .foregroundStyle(LAAColor.secondaryText)
                    // On the caption, not the row: a row's identifier would
                    // also rename its pictures.
                    .accessibilityIdentifier("work.session.echo")
            }
        }
        .laaImagePreview($preview)
    }
}

// MARK: - Pictures

enum LAAWorkAttachmentImage {
    /// The picture inside a composer attachment's data URI.
    static func image(_ attachment: Attachment) -> UIImage? {
        guard attachment.kind == .image, let base64 = attachment.uri.components(separatedBy: ",").last,
              let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }
}

/// One picture to its full size: the whole screen, black, pinch or double-tap
/// to zoom, swipe between the pictures of one message, and a close button.
struct LAAWorkImagePreview: View {
    struct Request: Identifiable {
        let id = UUID()
        let images: [UIImage]
        let index: Int
    }

    let request: Request
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(request.images.enumerated()), id: \.offset) { offset, image in
                    LAAZoomableImage(image: image).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: request.images.count > 1 ? .automatic : .never))
            .ignoresSafeArea()
            // On the pictures, not the whole stack: a container's identifier
            // would also rename the close button.
            .accessibilityIdentifier("work.image.preview")
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .conduitGlassControl(cornerRadius: 22, tint: .black.opacity(0.25), interactive: true)
            }
            .buttonStyle(.plain)
            .padding(LAASpacing.x4)
            .accessibilityLabel(Text(verbatim: "Close"))
            .accessibilityIdentifier("work.image.preview.close")
            .keyboardShortcut(.cancelAction)
        }
        .onAppear { index = request.index }
    }
}

private struct LAAZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var settled: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable().scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(MagnifyGesture()
                .onChanged { value in scale = min(5, max(1, settled * value.magnification)) }
                .onEnded { _ in settled = scale; if scale == 1 { reset() } })
            .simultaneousGesture(scale > 1 ? DragGesture()
                .onChanged { value in
                    offset = CGSize(width: settledOffset.width + value.translation.width,
                                    height: settledOffset.height + value.translation.height)
                }
                .onEnded { _ in settledOffset = offset } : nil)
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if scale > 1 { reset() } else { scale = 2.5; settled = 2.5 }
                }
            }
            .accessibilityLabel(Text(verbatim: "添付画像"))
            .accessibilityAddTraits(.isImage)
    }

    private func reset() {
        scale = 1; settled = 1; offset = .zero; settledOffset = .zero
    }
}

extension View {
    /// Presents a picture request over the whole screen.
    func laaImagePreview(_ request: Binding<LAAWorkImagePreview.Request?>) -> some View {
        fullScreenCover(item: request) { LAAWorkImagePreview(request: $0) }
    }
}
#endif
