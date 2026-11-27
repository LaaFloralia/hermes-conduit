#if LAA_BUILD
import SwiftUI
import UIKit

/// D-17: the pictures a decision carries. The Bridge keeps its own copy and
/// serves it with the decision's own auth (`GET /v1/decisions/:id/images/:img`,
/// `?size=thumb`); this device keeps what it fetched in memory and in Caches,
/// revalidated once per launch with the image's ETag.
enum LAADecisionImageSize: String, Hashable { case thumb, full }

struct LAADecisionImageKey: Hashable {
    let decisionID: String
    let imageID: String
    let size: LAADecisionImageSize

    /// The route, or nil when either id is not one the Bridge issues: no
    /// record text is ever joined into a path unchecked.
    var path: String? {
        guard decisionID.range(of: #"^dec_[0-9a-f]{16}$"#, options: .regularExpression) != nil,
              LAADecision.Image.validID(imageID) else { return nil }
        return "/v1/decisions/\(decisionID)/images/\(imageID)" + (size == .thumb ? "?size=thumb" : "")
    }

    fileprivate var name: String { "\(decisionID)-\(imageID).\(size.rawValue)" }
}

enum LAADecisionImagePhase: Equatable {
    case loading
    case loaded(UIImage)
    /// 404/410: retention removed it, or it never existed. Said quietly.
    case removed
    /// Not reachable now; nothing cached. No banner, only the empty frame.
    case unavailable
}

@MainActor
final class LAADecisionImageStore {
    static let shared = LAADecisionImageStore()

    /// The route's envelope (contract D-17 HTTP).
    struct Payload: Decodable {
        let contentType: String?
        let width: Int?
        let height: Int?
        let etag: String?
        let data: String
    }

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    /// Keys whose copy was confirmed by the Bridge in this launch.
    private var validated = Set<LAADecisionImageKey>()
    private var removed = Set<LAADecisionImageKey>()
    private var inflight: [LAADecisionImageKey: Task<LAADecisionImagePhase, Never>] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LAADecisionImages", isDirectory: true)
        memory.totalCostLimit = 96 * 1024 * 1024
        let folder = self.directory
        // The Bridge deletes a closed decision's pictures after 7 days; a copy
        // nobody opened for two weeks goes too.
        Task.detached(priority: .background) { Self.prune(folder, olderThan: 14 * 24 * 3600) }
    }

    /// What is already in memory, for the first frame.
    func cached(_ key: LAADecisionImageKey) -> UIImage? { memory.object(forKey: key.name as NSString) }

    /// The device's copy without asking the Bridge (memory, then disk).
    func local(_ key: LAADecisionImageKey) async -> UIImage? {
        if let image = cached(key) { return image }
        let file = file(key)
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return await UIImage(data: data)?.byPreparingForDisplay()
        }.value
        if let image { remember(image, for: key) }
        return image
    }

    /// The picture, asking the Bridge once per launch. Concurrent callers for
    /// the same key share one request.
    func load(_ key: LAADecisionImageKey, bridge: LAABridgeSession) async -> LAADecisionImagePhase {
        if removed.contains(key) { return .removed }
        if validated.contains(key), let image = cached(key) { return .loaded(image) }
        if let running = inflight[key] { return await running.value }
        let task = Task { await self.fetch(key, bridge: bridge) }
        inflight[key] = task
        let phase = await task.value
        inflight[key] = nil
        return phase
    }

    private func fetch(_ key: LAADecisionImageKey, bridge: LAABridgeSession) async -> LAADecisionImagePhase {
        let saved = await local(key)
        guard let path = key.path, bridge.status == .paired else {
            return saved.map(LAADecisionImagePhase.loaded) ?? .unavailable
        }
        do {
            let response: LAABridgeResponse<Payload> = try await bridge.request(
                method: "GET", path: path, ifNoneMatch: saved == nil ? nil : etag(key))
            guard let image = await adopt(response.data, etag: response.etag ?? response.data.etag, for: key) else {
                return saved.map(LAADecisionImagePhase.loaded) ?? .unavailable
            }
            validated.insert(key)
            return .loaded(image)
        } catch let error as LAABridgeHTTPError where error.status == 304 {
            validated.insert(key)
            return saved.map(LAADecisionImagePhase.loaded) ?? .unavailable
        } catch let error as LAABridgeHTTPError where Self.isRemoved(error) {
            forget(key)
            return .removed
        } catch {
            return saved.map(LAADecisionImagePhase.loaded) ?? .unavailable
        }
    }

    /// 410 is retention; 404 with the route's own code is an unknown picture.
    /// A 404 without it is an older Bridge with no image route: unavailable.
    nonisolated static func isRemoved(_ error: LAABridgeHTTPError) -> Bool {
        error.status == 410 || error.code == "decision_image_expired"
            || (error.status == 404 && error.code == "decision_image_not_found")
    }

    /// Decodes and stores one payload. Nil when the bytes are not a picture.
    func adopt(_ payload: Payload, etag: String?, for key: LAADecisionImageKey) async -> UIImage? {
        let decoded = await Task.detached(priority: .userInitiated) { () -> (Data, UIImage)? in
            guard let data = Data(base64Encoded: payload.data, options: .ignoreUnknownCharacters),
                  let image = await UIImage(data: data)?.byPreparingForDisplay() else { return nil }
            return (data, image)
        }.value
        guard let (data, image) = decoded else { return nil }
        remember(image, for: key)
        store(data, etag: etag, for: key)
        return image
    }

    #if DEBUG
    func resetForTesting() {
        memory.removeAllObjects(); validated = []; removed = []
        try? FileManager.default.removeItem(at: directory)
    }
    #endif

    // MARK: Cache

    private func file(_ key: LAADecisionImageKey) -> URL { directory.appendingPathComponent(key.name) }
    private func etagFile(_ key: LAADecisionImageKey) -> URL { directory.appendingPathComponent(key.name + ".etag") }
    private func etag(_ key: LAADecisionImageKey) -> String? {
        (try? String(contentsOf: etagFile(key), encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func remember(_ image: UIImage, for key: LAADecisionImageKey) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        memory.setObject(image, forKey: key.name as NSString, cost: Int(pixels * 4))
    }

    private func store(_ data: Data, etag: String?, for key: LAADecisionImageKey) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if let etag { try Data(etag.utf8).write(to: etagFile(key), options: .atomic) }
            else { try? FileManager.default.removeItem(at: etagFile(key)) }
        } catch {
            // Shown for this launch; the next one fetches it again.
            try? FileManager.default.removeItem(at: etagFile(key))
        }
    }

    private func forget(_ key: LAADecisionImageKey) {
        removed.insert(key)
        memory.removeObject(forKey: key.name as NSString)
        try? FileManager.default.removeItem(at: file(key))
        try? FileManager.default.removeItem(at: etagFile(key))
    }

    nonisolated private static func prune(_ directory: URL, olderThan age: TimeInterval) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentAccessDateKey, .contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-age)
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
            if let used = values?.contentAccessDate ?? values?.contentModificationDate, used < limit {
                try? manager.removeItem(at: file)
            }
        }
    }
}

enum LAADecisionImageCopy {
    static let removed = "画像は削除されました"
    static let unavailable = "画像を表示できません"
    static let openHint = "全画面で拡大できます"

    /// 「画像1（全2枚）」
    static func general(_ index: Int, of count: Int) -> String {
        count > 1 ? "画像\(index + 1)（全\(count)枚）" : "画像"
    }
    /// 「<選択肢>の画像」
    static func option(_ label: String) -> String { "\(label)の画像" }
}

/// One picture at a fixed frame: the Bridge's copy filled into the frame,
/// a quiet surface while it loads, and a small line when it was removed.
struct LAADecisionImageView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let decisionID: String
    let image: LAADecision.Image
    let size: LAADecisionImageSize
    var contentMode: ContentMode = .fill
    /// The phase reaches the parent (the viewer keeps zoom on a loaded picture).
    var onPhase: ((LAADecisionImagePhase) -> Void)? = nil
    @State private var phase: LAADecisionImagePhase = .loading

    private var key: LAADecisionImageKey { .init(decisionID: decisionID, imageID: image.id, size: size) }

    var body: some View {
        ZStack {
            switch phase {
            case .loaded(let picture):
                Image(uiImage: picture).resizable().aspectRatio(contentMode: contentMode)
            case .loading:
                LAAColor.subtleSurface
            case .removed:
                LAAColor.subtleSurface
                placeholder(LAADecisionImageCopy.removed, identifier: "work.decision.image.removed")
            case .unavailable:
                LAAColor.subtleSurface
                Image(systemName: "photo").imageScale(.medium).foregroundStyle(LAAColor.secondaryText)
                    .accessibilityLabel(Text(verbatim: LAADecisionImageCopy.unavailable))
            }
        }
        .task(id: key) {
            if let first = LAADecisionImageStore.shared.cached(key) { set(.loaded(first)) }
            else if let local = await LAADecisionImageStore.shared.local(key) { set(.loaded(local)) }
            else { set(.loading) }
            let result = await LAADecisionImageStore.shared.load(key, bridge: bridge)
            guard !Task.isCancelled else { return }
            set(result)
        }
    }

    private func set(_ next: LAADecisionImagePhase) {
        if next != phase { phase = next }
        onPhase?(next)
    }

    private func placeholder(_ text: String, identifier: String) -> some View {
        VStack(spacing: LAASpacing.x1) {
            #if targetEnvironment(macCatalyst)
            // The Mac's larger type leaves a 72 pt thumbnail room for the words only.
            Text(verbatim: text).multilineTextAlignment(.center).lineLimit(4).minimumScaleFactor(0.7)
            #else
            Image(systemName: "photo").imageScale(.small).accessibilityHidden(true)
            Text(verbatim: text).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
            #endif
        }
        .laaTextStyle(.secondary)
        .foregroundStyle(LAAColor.secondaryText)
        .padding(LAASpacing.x2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

/// The general pictures under the summary. One picture spans the column at
/// its own proportions; several sit in a strip that scrolls sideways.
struct LAADecisionImageStrip: View {
    @Environment(\.laaDesktop) private var laaDesktop
    let item: LAADecision
    let open: (LAADecision.Image) -> Void

    private var images: [LAADecision.Image] { item.generalImages }
    private var height: CGFloat { laaDesktop ? 200 : 160 }

    var body: some View {
        if images.count == 1, let only = images.first {
            thumb(only, index: 0)
                .aspectRatio(only.aspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: laaDesktop ? 420 : 320, alignment: .leading)
        } else if !images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LAASpacing.x2) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        thumb(image, index: index)
                            .frame(width: height * min(max(image.aspect, 0.6), 2.2), height: height)
                    }
                }
            }
            .scrollClipDisabled()
            .accessibilityIdentifier("work.decision.images")
        }
    }

    private func thumb(_ image: LAADecision.Image, index: Int) -> some View {
        Button { open(image) } label: {
            LAADecisionImageView(decisionID: item.id, image: image, size: .thumb)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(LAADecisionPressStyle())
        .accessibilityLabel(Text(verbatim: LAADecisionImageCopy.general(index, of: images.count)))
        .accessibilityHint(Text(verbatim: LAADecisionImageCopy.openHint))
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("work.decision.image.\(index)")
    }
}

/// Set while a decision's picture viewer is open, so the board's list leaves
/// Esc to the viewer instead of clearing the selection under it. An
/// environment value reaches the split view's detail column.
private struct LAADecisionViewerOpenKey: EnvironmentKey {
    static let defaultValue: Binding<Bool>? = nil
}

extension EnvironmentValues {
    var laaDecisionViewerOpen: Binding<Bool>? {
        get { self[LAADecisionViewerOpenKey.self] }
        set { self[LAADecisionViewerOpenKey.self] = newValue }
    }
}

/// Every picture of one decision over the whole screen: pinch or double-tap
/// to zoom, drag to pan, swipe between pictures, close (Esc on the Mac).
struct LAADecisionImageViewer: View {
    struct Request: Identifiable {
        let id = UUID()
        let item: LAADecision
        let start: LAADecision.Image
    }

    let request: Request
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    private var images: [LAADecision.Image] { request.item.viewerImages }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // The viewer always reads dark (set below), so the paper turns to
            // the dark set's ground and the picture keeps its own colours.
            LAAColor.background.ignoresSafeArea()
            pager
            closeButton
        }
        .overlay(alignment: .bottom) { caption }
        .onAppear { index = images.firstIndex(of: request.start) ?? 0 }
        .environment(\.colorScheme, .dark)
        // The clock and battery would read dark on the dark ground; a picture
        // viewer gives the whole screen to the picture instead.
        .statusBarHidden(true)
    }

    private var indexDisplay: PageTabViewStyle.IndexDisplayMode { images.count > 1 ? .automatic : .never }

    private var pager: some View {
        TabView(selection: $index) {
            ForEach(Array(images.enumerated()), id: \.element.id) { offset, image in
                page(image, offset)
            }
        }
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: indexDisplay))
        .ignoresSafeArea()
        .accessibilityIdentifier("work.decision.viewer")
    }

    private func page(_ image: LAADecision.Image, _ offset: Int) -> some View {
        LAADecisionViewerPage(item: request.item, image: image, index: offset, label: label(image, offset))
            .tag(offset)
    }

    private var closeButton: some View {
        LAACloseButton(glass: true) { dismiss() }
            .padding(LAASpacing.x4)
            .accessibilityIdentifier("work.decision.viewer.close")
            .keyboardShortcut(.cancelAction)
    }

    /// An option's picture names its option; general pictures need no words.
    @ViewBuilder private var caption: some View {
        if images.indices.contains(index), let option = images[index].option,
           request.item.options.indices.contains(option) {
            Text(verbatim: request.item.options[option].label)
                .laaTextStyle(.secondary)
                .foregroundStyle(LAAColor.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, LAASpacing.horizontal)
                .padding(.bottom, images.count > 1 ? LAASpacing.x8 + LAASpacing.x4 : LAASpacing.x6)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    private func label(_ image: LAADecision.Image, _ offset: Int) -> String {
        if let option = image.option, request.item.options.indices.contains(option) {
            return LAADecisionImageCopy.option(request.item.options[option].label)
        }
        return LAADecisionImageCopy.general(offset, of: images.count)
    }
}

/// One page: the thumb at once (already zoomable), replaced by the full copy.
private struct LAADecisionViewerPage: View {
    let item: LAADecision
    let image: LAADecision.Image
    let index: Int
    let label: String
    @EnvironmentObject private var bridge: LAABridgeSession
    @State private var picture: UIImage?
    @State private var removed = false

    var body: some View {
        ZStack {
            if let picture {
                LAADecisionZoomView(image: picture, identifier: "work.decision.viewer.page.\(index)", label: label)
            } else if removed {
                VStack(spacing: LAASpacing.x2) {
                    Image(systemName: "photo").imageScale(.large).accessibilityHidden(true)
                    Text(verbatim: LAADecisionImageCopy.removed)
                }
                .laaTextStyle(.body)
                .foregroundStyle(LAAColor.secondaryText)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("work.decision.viewer.removed")
            } else {
                LAALoadingDots()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: image.id) {
            let store = LAADecisionImageStore.shared
            let thumb = LAADecisionImageKey(decisionID: item.id, imageID: image.id, size: .thumb)
            let full = LAADecisionImageKey(decisionID: item.id, imageID: image.id, size: .full)
            if picture == nil { picture = store.cached(full) ?? store.cached(thumb) }
            if picture == nil, let local = await store.local(full) { picture = local }
            switch await store.load(full, bridge: bridge) {
            case .loaded(let value): picture = value
            case .removed: if picture == nil { removed = true }
            case .loading, .unavailable:
                if picture == nil, case .loaded(let value) = await store.load(thumb, bridge: bridge) { picture = value }
                else if picture == nil { removed = true }
            }
        }
    }
}

/// UIScrollView zoom: pinch (trackpad pinch on the Mac), double-tap to 2.5×
/// at the tapped point and back, pan while zoomed. VoiceOver reads the zoom.
struct LAADecisionZoomView: UIViewRepresentable {
    let image: UIImage
    let identifier: String
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class ScrollView: UIScrollView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    }

    func makeUIView(context: Context) -> ScrollView {
        let scroll = ScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scroll = scroll
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        update(context.coordinator)
        scroll.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layout() }
        return scroll
    }

    func updateUIView(_ scroll: ScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image { context.coordinator.imageView?.image = image }
        update(context.coordinator)
        context.coordinator.layout()
    }

    private func update(_ coordinator: Coordinator) {
        guard let view = coordinator.imageView else { return }
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = label
        coordinator.reportZoom()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scroll: UIScrollView?
        private var lastBounds: CGSize = .zero

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { center(); reportZoom() }

        /// Fits the picture at 1× whenever the page changes size.
        func layout() {
            guard let scroll, let imageView else { return }
            let bounds = scroll.bounds.size
            guard bounds.width > 0, bounds.height > 0, bounds != lastBounds else { return }
            lastBounds = bounds
            if scroll.zoomScale != 1 { scroll.setZoomScale(1, animated: false) }
            imageView.frame = CGRect(origin: .zero, size: bounds)
            scroll.contentSize = bounds
            center()
        }

        private func center() {
            guard let scroll, let imageView else { return }
            let x = max(0, (scroll.bounds.width - imageView.frame.width) / 2)
            let y = max(0, (scroll.bounds.height - imageView.frame.height) / 2)
            scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        func reportZoom() {
            guard let scroll, let imageView else { return }
            imageView.accessibilityValue = "\(Int((scroll.zoomScale * 100).rounded()))%"
        }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll, let imageView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}
#endif
