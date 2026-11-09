#if LAA_BUILD
import SwiftUI
import UIKit

/// Who the owner is in every conversation: the name, and the role label only
/// the owner carries.
enum LAAOwnerIdentity {
    static let name = "LAA"
    static let role = "Administration"
    static let initial = "L"
    /// VoiceOver reads the header as one phrase.
    static var spokenHeader: String { "\(name)、\(role)" }
}

/// The owner's picture. The Mac's LAA Bridge holds the one copy
/// (`/v1/owner/avatar`), so the iPhone and both Macs show the same face; each
/// device keeps the last picture it fetched for when the Mac is out of reach.
/// No picture anywhere falls back to the initial.
@MainActor
final class LAAOwnerAvatarStore: ObservableObject {
    static let shared = LAAOwnerAvatarStore()

    /// The side of the uploaded square, in pixels.
    static let pixelSize: CGFloat = 256
    static let path = "/v1/owner/avatar"

    @Published private(set) var image: UIImage?
    @Published private(set) var busy = false

    private let directory: URL
    private let defaults: UserDefaults
    private let etagKey = "laa.owner.avatar.etag"
    /// A UI test's picture is fixed: no fetch replaces it.
    private var pinned = false

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LAAOwner", isDirectory: true)
        self.defaults = defaults
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_OWNER_AVATAR") {
            image = Self.fixtureImage()
            pinned = true
            return
        }
        #endif
        if let data = try? Data(contentsOf: file) { image = UIImage(data: data) }
    }

    private var file: URL { directory.appendingPathComponent("avatar.img") }
    var etag: String? { image == nil ? nil : defaults.string(forKey: etagKey) }

    // MARK: - Reading

    struct Payload: Decodable { let contentType: String; let etag: String; let data: String }
    struct Saved: Decodable { let contentType: String; let etag: String }
    private struct Removed: Decodable { let removed: Bool }

    enum Outcome: Equatable { case updated, unchanged, cleared, kept }

    /// One read from the Mac. 404 means nobody set a picture, so the cached
    /// copy goes too; any other failure keeps what this device already has.
    @discardableResult
    func refresh(bridge: LAABridgeSession) async -> Outcome {
        guard !pinned, bridge.status == .paired else { return .kept }
        do {
            let response: LAABridgeResponse<Payload> = try await bridge.request(
                method: "GET", path: Self.path, ifNoneMatch: etag)
            return apply(response.data) ? .updated : .kept
        } catch let error as LAABridgeHTTPError where error.status == 304 {
            return .unchanged
        } catch let error as LAABridgeHTTPError where error.status == 404 {
            clear()
            return .cleared
        } catch {
            return .kept
        }
    }

    /// Adopts a payload from the Mac. False (and nothing changes) when the
    /// bytes are not a picture.
    @discardableResult
    func apply(_ payload: Payload) -> Bool {
        guard let data = Data(base64Encoded: payload.data), let picture = UIImage(data: data) else { return false }
        store(data, etag: payload.etag)
        image = picture
        return true
    }

    // MARK: - Writing

    enum SaveError: Error, Equatable { case unreadableImage, notPaired }

    /// Crops to the centre square, scales to 256 px and sends it as JPEG.
    func save(_ picture: UIImage, bridge: LAABridgeSession) async throws {
        guard bridge.status == .paired else { throw SaveError.notPaired }
        guard let data = Self.prepared(picture) else { throw SaveError.unreadableImage }
        busy = true
        defer { busy = false }
        struct Body: Encodable { let contentType: String; let data: String }
        let body = try JSONEncoder().encode(Body(contentType: "image/jpeg", data: data.base64EncodedString()))
        let response: LAABridgeResponse<Saved> = try await bridge.request(method: "PUT", path: Self.path, jsonBody: body)
        store(data, etag: response.data.etag)
        image = UIImage(data: data)
    }

    func remove(bridge: LAABridgeSession) async throws {
        guard bridge.status == .paired else { throw SaveError.notPaired }
        busy = true
        defer { busy = false }
        let _: LAABridgeResponse<Removed> = try await bridge.request(method: "DELETE", path: Self.path)
        clear()
    }

    /// The square, 256 px JPEG the Mac stores. Nil when the picture has no
    /// pixels to draw.
    nonisolated static func prepared(_ picture: UIImage) -> Data? {
        let width = picture.size.width * picture.scale, height = picture.size.height * picture.scale
        guard width >= 1, height >= 1 else { return nil }
        let side = min(width, height)
        let target = min(pixelSize, side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let scale = target / side
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            // The centre square: the longer side overflows equally both ways.
            let size = CGSize(width: width * scale, height: height * scale)
            picture.draw(in: CGRect(x: (target - size.width) / 2, y: (target - size.height) / 2,
                                    width: size.width, height: size.height))
        }
        return drawn.jpegData(compressionQuality: 0.85)
    }

    // MARK: - Cache

    private func store(_ data: Data, etag: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            defaults.set(etag, forKey: etagKey)
        } catch {
            // The picture still shows this session; the next launch fetches it again.
            defaults.removeObject(forKey: etagKey)
        }
    }

    private func clear() {
        try? FileManager.default.removeItem(at: file)
        defaults.removeObject(forKey: etagKey)
        image = nil
    }

    #if DEBUG
    /// A soft teal-and-plum square, standing in for a photo in UI tests.
    static func fixtureImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { context in
            let colors = [UIColor(red: 0.0, green: 0.35, blue: 0.37, alpha: 1).cgColor,
                          UIColor(red: 0.42, green: 0.14, blue: 0.30, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 256, y: 256), options: [])
            UIColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 0.9).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 88, y: 56, width: 80, height: 80))
            context.cgContext.fillEllipse(in: CGRect(x: 48, y: 152, width: 160, height: 140))
        }
    }
    #endif
}

/// The owner's face: the picture, or the initial on the own-bubble colour.
struct LAAOwnerAvatarView: View {
    @ObservedObject private var store = LAAOwnerAvatarStore.shared
    var size: CGFloat = LAASender.avatarSize

    var body: some View {
        Group {
            if let image = store.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(verbatim: LAAOwnerIdentity.initial)
                    .font(.custom("Georgia", size: size * 0.5).weight(.semibold))
                    .foregroundStyle(LAAColor.ownBubbleText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LAAColor.ownBubble)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

extension View {
    /// Keeps the owner's picture current on this device: on launch, when the
    /// pairing changes and when the app comes back.
    func laaOwnerAvatarSync(_ bridge: LAABridgeSession, active: Bool) -> some View {
        task(id: "\(bridge.revision)|\(active)") {
            guard active else { return }
            await LAAOwnerAvatarStore.shared.refresh(bridge: bridge)
        }
    }
}
#endif
