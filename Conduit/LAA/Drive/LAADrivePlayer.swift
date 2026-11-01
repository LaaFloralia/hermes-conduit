#if LAA_BUILD
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// AVFoundation asks for byte ranges on a private URL. The actual requests use
/// the existing Bridge session, so its bearer is never placed in a URL.
@MainActor
final class LAADrivePlayer: NSObject, ObservableObject, @preconcurrency AVAssetResourceLoaderDelegate {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var error: String?
    let player = AVPlayer()
    private let item: LAADriveItem
    private let bridge: LAABridgeSession
    private let studioPath: String?
    private let localURL: URL?
    private var resolvedVersion: String?
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var observer: Any?
    private var statusObservation: NSKeyValueObservation?

    init(item: LAADriveItem, bridge: LAABridgeSession, studioPath: String? = nil, localURL: URL? = nil) {
        self.item = item; self.bridge = bridge; self.studioPath = studioPath; self.localURL = localURL
        self.resolvedVersion = item.version.flatMap { LAADrivePaths.validVersion($0) ? $0 : nil }
        super.init()
        open()
    }

    func open() {
        guard player.currentItem == nil else { return }
        error = nil
        let url: URL
        if let localURL, localURL.isFileURL {
            url = localURL
        } else {
            guard localURL == nil,
                  (studioPath.map(LAAStudioMedia.bridgePathIsValid) ?? ((try? LAADrivePaths.content(item.id)) != nil)),
                  let remoteURL = URL(string: "laa-drive://asset/\(item.id)") else {
                error = LAABridgeError.invalidResponse.japaneseText
                return
            }
            url = remoteURL
        }
        let asset = AVURLAsset(url: url)
        if localURL == nil { asset.resourceLoader.setDelegate(self, queue: .main) }
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 15
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] value, _ in
            guard value.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.error == nil else { return }
                self.error = LAACopy.Drive.invalidPreview
                self.playing = false
            }
        }
        player.replaceCurrentItem(with: playerItem)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.position = max(0, seconds) }
                let total = self.player.currentItem?.duration.seconds ?? 0
                if total.isFinite && total > 0 { self.duration = total }
            }
        }
    }

    func toggle() {
        guard error == nil else { return }
        if playing { player.pause() } else { player.play() }
        playing.toggle()
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        position = seconds
    }
    func close() {
        player.pause(); playing = false
        requests.values.forEach { $0.cancel() }; requests.removeAll()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        duration = 0; position = 0
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        let id = ObjectIdentifier(request)
        requests[id] = Task {
            defer { requests.removeValue(forKey: id) }
            do {
                try await fill(request)
                try Task.checkCancellation()
                request.finishLoading()
            } catch is CancellationError { }
            catch {
                self.error = LAADrivePresentation.message(error)
                self.playing = false
                request.finishLoading(with: error)
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel request: AVAssetResourceLoadingRequest) {
        // AVFoundation cancels obsolete loading requests on seek; stop the
        // corresponding Bridge transfer as soon as that happens.
        requests.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }

    private func fill(_ request: AVAssetResourceLoadingRequest) async throws {
        let dataRequest = request.dataRequest
        var offset = dataRequest.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
        let requestedEnd: Int64
        if let dataRequest, !dataRequest.requestsAllDataToEndOfResource {
            let (end, overflow) = dataRequest.requestedOffset.addingReportingOverflow(Int64(dataRequest.requestedLength))
            guard !overflow else { throw LAADriveRangeError.invalidRange }
            requestedEnd = end
        } else { requestedEnd = Int64.max }
        var expectedTotal: Int64?
        repeat {
            try Task.checkCancellation()
            let remaining = requestedEnd == Int64.max ? LAADriveContent.chunkSize :
                Int(min(Int64(LAADriveContent.chunkSize), max(1, requestedEnd - offset)))
            let result: LAADriveRangeResponse
            if let studioPath {
                result = try await bridge.driveRange(path: studioPath, offset: offset, length: remaining)
            } else {
                result = try await LAADriveContent.range(item, offset: offset, length: remaining, bridge: bridge,
                                                         expectedVersion: resolvedVersion)
                if let version = result.version {
                    guard resolvedVersion == nil || resolvedVersion == version else { throw LAADriveRangeError.versionChanged }
                    resolvedVersion = version
                } else if resolvedVersion != nil { throw LAADriveRangeError.versionChanged }
            }
            guard expectedTotal == nil || expectedTotal == result.total else { throw LAADriveRangeError.invalidRange }
            expectedTotal = result.total
            if let info = request.contentInformationRequest {
                info.contentType = UTType(mimeType: result.mimeType ?? item.mimeType)?.identifier ?? UTType.data.identifier
                info.contentLength = result.total
                info.isByteRangeAccessSupported = true
            }
            guard let dataRequest else { return }
            dataRequest.respond(with: result.data)
            offset += Int64(result.data.count)
        } while offset < min(requestedEnd, expectedTotal ?? 0)
    }
}

struct LAADrivePlayerView: View {
    @StateObject private var owner: LAADrivePlayerOwner
    let item: LAADriveItem
    let onStateChange: (LAADrivePlaybackState) -> Void

    /// Studio paths are validated content-addressed Bridge paths. Drive does
    /// not autoplay by default; callers can opt in and observe player state.
    init(item: LAADriveItem, bridge: LAABridgeSession, studioPath: String? = nil,
         autoPlay: Bool = false, onStateChange: @escaping (LAADrivePlaybackState) -> Void = { _ in }) {
        self.item = item
        self.onStateChange = onStateChange
        _owner = StateObject(wrappedValue: LAADrivePlayerOwner(item: item, bridge: bridge,
                                                                studioPath: studioPath, autoPlay: autoPlay))
    }
    var body: some View {
        LAADrivePlayerContent(owner: owner, onStateChange: onStateChange)
    }
}

/// Used by the offline screen with the same native controls and ownership.
struct LAADrivePlayerContent: View {
    @ObservedObject var owner: LAADrivePlayerOwner
    var onStateChange: (LAADrivePlaybackState) -> Void = { _ in }

    var body: some View {
        VStack(spacing: LAASpacing.x4) {
            LAADriveNativePlayerSurface(player: owner.source.player, delegate: owner)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(LAAColor.subtleSurface)
                .accessibilityIdentifier("laa.drive.player")
            switch owner.state {
            case .loading:
                ProgressView("Loading")
            case .failed(let message):
                Text(verbatim: message).laaTextStyle(.body).foregroundStyle(LAAColor.attention)
                if owner.canRetry {
                    Button("Retry") { owner.playback.retry() }
                        .accessibilityIdentifier("laa.drive.player.retry")
                }
            case .ended:
                Button("Play again") { owner.playback.replay() }
                    .accessibilityIdentifier("laa.drive.player.replay")
            case .paused, .playing:
                EmptyView()
            }
        }
        .padding(LAASpacing.horizontal)
        .onAppear { owner.appear() }
        .onDisappear { owner.disappear() }
        .onChange(of: owner.state, initial: true) { _, state in onStateChange(state) }
    }
}
#endif
