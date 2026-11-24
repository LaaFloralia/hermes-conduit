#if LAA_BUILD
import SwiftUI

/// A reply while it streams, drawn without the transcript moving under the
/// reader (ADVICE-V2 §3.5 "Smoothness", HO-04):
///
/// - commits arrive at most every 50 ms (the last one always lands);
/// - the text is cut at safe block boundaries (`MarkdownStableBoundaryScanner`):
///   finished blocks are frozen chunks with stable ids that parse once and
///   keep their measured height; only the tail block re-parses;
/// - no implicit animation ever reaches a row's height.
struct LAAStreamingText: View {
    let text: String
    let active: Bool
    var gatewayMediaDataURL: ((String) async -> String?)? = nil

    @State private var model = LAAStreamingModel()
    @State private var commitTask: Task<Void, Never>?
    @Environment(\.chatTextSize) private var chatTextSize

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownProseRun.Spacing.betweenBlocks) {
            ForEach(model.chunks) { chunk in
                LAAFrozenChunk(chunk: chunk, fontEpoch: chatTextSize.cacheIdentity,
                               gatewayMediaDataURL: gatewayMediaDataURL)
                    .equatable()
            }
            if !model.tail.isEmpty {
                MarkdownText(source: model.tail, gatewayMediaDataURL: gatewayMediaDataURL, isStreaming: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
        .onAppear { model.commit(text) }
        .onChange(of: text) { _, newText in schedule(newText) }
        .onChange(of: active) { _, isActive in
            // The last words land at once when the stream ends.
            if !isActive { commitTask?.cancel(); commitTask = nil; model.commit(text) }
        }
        .onDisappear { commitTask?.cancel(); commitTask = nil }
    }

    /// At most one commit per `LAAStreamingModel.commitInterval`; the
    /// newest text always lands.
    private func schedule(_ newText: String) {
        let wait = model.delayBeforeNextCommit(now: Date())
        guard wait > 0 else { model.commit(newText); return }
        guard commitTask == nil else { return }
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int((wait * 1000).rounded(.up))))
            commitTask = nil
            guard !Task.isCancelled else { return }
            model.commit(text)
        }
    }
}

/// A finished block: parsed once, measured once, then held at its height.
private struct LAAFrozenChunk: View, Equatable {
    let chunk: LAAStreamingModel.Chunk
    let fontEpoch: String
    let gatewayMediaDataURL: ((String) async -> String?)?
    @State private var width: CGFloat = 0

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.chunk == rhs.chunk && lhs.fontEpoch == rhs.fontEpoch }

    var body: some View {
        let key = LAATranscriptHeightCache.Key(id: chunk.id, revision: chunk.text.hashValue, width: width, epoch: fontEpoch)
        MarkdownText(source: chunk.text, gatewayMediaDataURL: gatewayMediaDataURL, isStreaming: false)
            .frame(minHeight: LAATranscriptHeightCache.shared.height(for: key), alignment: .top)
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                if abs(size.width - width) > 0.5 { width = size.width }
                LAATranscriptHeightCache.shared.store(size.height,
                    for: LAATranscriptHeightCache.Key(id: chunk.id, revision: chunk.text.hashValue, width: size.width, epoch: fontEpoch))
            }
    }
}

/// The streaming reply's chunks: everything before the last safe boundary
/// is frozen; the rest is the tail.
struct LAAStreamingModel {
    /// `motion` budget for a streaming commit.
    static let commitInterval: TimeInterval = 0.05

    struct Chunk: Identifiable, Equatable {
        /// The chunk's start in the reply (UTF-8 offset): stable while the
        /// reply grows.
        let id: Int
        let text: String
    }

    private(set) var chunks: [Chunk] = []
    private(set) var tail = ""
    private(set) var committed = ""
    private(set) var lastCommit: Date?
    private var scanner = MarkdownStableBoundaryScanner()
    private var frozenBytes = 0

    func delayBeforeNextCommit(now: Date) -> TimeInterval {
        guard let lastCommit else { return 0 }
        return max(0, Self.commitInterval - now.timeIntervalSince(lastCommit))
    }

    /// Takes the newest text. A text that does not extend the last one (a
    /// rewrite, a new reply) starts the chunks over.
    mutating func commit(_ text: String, at now: Date = Date()) {
        lastCommit = now
        guard text != committed else { return }
        if !text.hasPrefix(committed) { self = LAAStreamingModel(); lastCommit = now }
        let delta = String(decoding: Array(text.utf8).dropFirst(committed.utf8.count), as: UTF8.self)
        committed = text
        let boundaries = scanner.append(delta)
        let bytes = Array(text.utf8)
        // Freeze up to the newest boundary that leaves a non-empty tail.
        if let boundary = boundaries.last(where: { $0 > frozenBytes && $0 < bytes.count }) {
            let slice = String(decoding: bytes[frozenBytes..<boundary], as: UTF8.self)
            let trimmed = slice.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty { chunks.append(Chunk(id: frozenBytes, text: trimmed)) }
            frozenBytes = boundary
        }
        tail = String(decoding: bytes[min(frozenBytes, bytes.count)...], as: UTF8.self)
    }
}

/// Measured heights of transcript pieces whose content no longer changes,
/// keyed by (content revision, width, text scale / font epoch): a row that
/// leaves the screen and comes back takes its last height at once.
@MainActor
final class LAATranscriptHeightCache {
    static let shared = LAATranscriptHeightCache()

    struct Key: Hashable {
        let id: Int
        let revision: Int
        let width: CGFloat
        let epoch: String

        init(id: Int, revision: Int, width: CGFloat, epoch: String) {
            self.id = id
            self.revision = revision
            self.width = (width * 2).rounded() / 2
            self.epoch = epoch
        }
    }

    private var heights: [Key: CGFloat] = [:]
    private let limit = 2_048

    func height(for key: Key) -> CGFloat? {
        guard key.width > 0 else { return nil }
        return heights[key]
    }

    func store(_ height: CGFloat, for key: Key) {
        guard key.width > 0, height > 0 else { return }
        if heights.count >= limit { heights.removeAll(keepingCapacity: true) }
        heights[key] = height
    }
}
#endif
