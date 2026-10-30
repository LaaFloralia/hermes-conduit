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
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var observer: Any?
    private var endObservation: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    init(item: LAADriveItem, bridge: LAABridgeSession) {
        self.item = item; self.bridge = bridge
        super.init()
        open()
    }

    func open() {
        guard player.currentItem == nil else { return }
        error = nil
        guard (try? LAADrivePaths.content(item.id)) != nil,
              let url = URL(string: "laa-drive://asset/\(item.id)") else {
            error = LAABridgeError.invalidResponse.japaneseText
            return
        }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .main)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 15
        endObservation = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                                 object: playerItem, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.playing = false
                self?.player.seek(to: .zero)
            }
        }
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
        if let endObservation { NotificationCenter.default.removeObserver(endObservation); self.endObservation = nil }
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
            let result = try await LAADriveContent.range(item, offset: offset, length: remaining, bridge: bridge)
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
    @StateObject private var model: LAADrivePlayer
    @State private var dragging = false
    @State private var dragPosition = 0.0
    let item: LAADriveItem

    init(item: LAADriveItem, bridge: LAABridgeSession) {
        self.item = item
        _model = StateObject(wrappedValue: LAADrivePlayer(item: item, bridge: bridge))
    }
    var body: some View {
        VStack(spacing: LAASpacing.x6) {
            if item.mimeType.hasPrefix("video/") {
                LAADrivePlayerSurface(player: model.player).aspectRatio(16 / 9, contentMode: .fit)
                    .background(LAAColor.subtleSurface)
            } else {
                Image(systemName: "waveform").font(LAAType.screenTitle).foregroundStyle(LAAColor.link)
                    .frame(maxWidth: .infinity, minHeight: LAASpacing.section * 4)
            }
            if let error = model.error {
                Text(verbatim: error).laaTextStyle(.body).foregroundStyle(LAAColor.attention)
            }
            HStack(spacing: LAASpacing.x4) {
                Button { model.toggle() } label: {
                    Label(model.playing ? LAACopy.Drive.pause : LAACopy.Drive.play,
                          systemImage: model.playing ? "pause.fill" : "play.fill")
                }.accessibilityIdentifier("laa.drive.play")
                Slider(value: Binding(get: { dragging ? dragPosition : min(model.position, max(model.duration, 1)) },
                                      set: { dragPosition = $0 }), in: 0...max(model.duration, 1),
                       onEditingChanged: { active in
                           dragging = active
                           if !active { model.seek(dragPosition) }
                       })
                    .disabled(model.duration <= 0 || model.error != nil)
                    .accessibilityLabel(Text(verbatim: LAACopy.Drive.seek))
                    .accessibilityIdentifier("laa.drive.seek")
            }
        }
        .padding(LAASpacing.horizontal)
        .onAppear { model.open() }
        .onDisappear { model.close() }
    }
}

private struct LAADrivePlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerView { let view = PlayerView(); view.layerPlayer.player = player; return view }
    func updateUIView(_ view: PlayerView, context: Context) { view.layerPlayer.player = player }
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var layerPlayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#endif
