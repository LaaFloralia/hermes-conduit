import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LAAKit

@MainActor
struct OwnerProfileStoreTests {
    nonisolated static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("laa-owner-profile-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A solid-colour image of the given size, encoded as `type`.
    nonisolated static func jpeg(width: Int, height: Int, type: String = "public.jpeg") -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.6, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out as CFMutableData, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    nonisolated static func pixelSize(_ data: Data) -> (Int, Int, String?)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h, CGImageSourceGetType(source) as String?)
    }

    private func makeStore(_ dir: URL? = nil) -> LAAOwnerProfileStore {
        LAAOwnerProfileStore(appGroup: nil, directory: dir ?? Self.temporaryDirectory())
    }

    @Test func constants() {
        #expect(LAAOwnerProfileStore.defaultAppGroup == "group.com.laa-inc.shared")
        #expect(LAAOwnerProfileStore.defaultKeychainAccessGroup == "PAW258GB42.com.laa-inc.shared")
        #expect(LAAOwnerProfileStore.defaultDisplayName == "LAA")
        #expect(LAAOwnerProfileStore.changedNotification == "com.laa-inc.shared.owner-profile.changed")
    }

    @Test func defaultsInEmptyDirectory() {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(store.displayName == "LAA")
        #expect(store.initial == "L")
        #expect(store.avatarData == nil)
        #expect(store.avatarImage == nil)
        #expect(!store.isCustomName)
        #expect(!store.isSharedContainer) // an explicit directory is never the shared one
        #expect(store.storageLocationDescription == store.directory.path)
    }

    @Test func displayNameSaveReloadReset() throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        store.saveDisplayName("  ayame \n")
        #expect(store.displayName == "ayame")
        #expect(store.initial == "A")
        #expect(store.isCustomName)

        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent(LAAOwnerProfileStore.profileFileName))) as? [String: Any]
        #expect(json?["displayName"] as? String == "ayame")

        // Another app (a second store on the same files) sees it, and reload picks up its change.
        let other = makeStore(dir)
        #expect(other.displayName == "ayame")
        other.saveDisplayName("Saya")
        store.reload()
        #expect(store.displayName == "Saya")

        // Empty resets to LAA.
        store.saveDisplayName("   ")
        #expect(store.displayName == "LAA")
        #expect(!store.isCustomName)
        other.reload()
        #expect(other.displayName == "LAA")
    }

    @Test func initialOfNames() {
        #expect(LAAOwnerProfileStore.initial(of: "laa") == "L")
        #expect(LAAOwnerProfileStore.initial(of: "") == "L")
        #expect(LAAOwnerProfileStore.initial(of: "ßeta") == "S")
        #expect(LAAOwnerProfileStore.initial(of: "社長") == "社")
        #expect(LAAOwnerProfileStore.initial(of: "👩🏽‍💻 dev") == "👩🏽‍💻")
        #expect(LAAOwnerProfileStore.resolvedName(nil) == "LAA")
    }

    @Test func avatarIsCroppedTo256Square() throws {
        let landscape = try #require(LAAOwnerProfileStore.preparedAvatarJPEG(from: Self.jpeg(width: 1200, height: 800)))
        let size = try #require(Self.pixelSize(landscape))
        #expect(size.0 == 256 && size.1 == 256)
        #expect(size.2 == "public.jpeg")

        let portrait = try #require(LAAOwnerProfileStore.preparedAvatarJPEG(
            from: Self.jpeg(width: 300, height: 900, type: "public.png")))
        let p = try #require(Self.pixelSize(portrait))
        #expect(p.0 == 256 && p.1 == 256)

        // Small pictures are squared but not enlarged.
        let small = try #require(LAAOwnerProfileStore.preparedAvatarJPEG(from: Self.jpeg(width: 120, height: 90)))
        let s = try #require(Self.pixelSize(small))
        #expect(s.0 == 90 && s.1 == 90)

        #expect(LAAOwnerProfileStore.preparedAvatarJPEG(from: Data("not an image".utf8)) == nil)
        #expect(LAAOwnerProfileStore.preparedAvatarJPEG(from: Data()) == nil)
    }

    @Test func avatarSaveReloadRemove() throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        try store.saveAvatar(imageData: Self.jpeg(width: 640, height: 480))
        let data = try #require(store.avatarData)
        #expect(store.avatarImage != nil)
        let size = try #require(Self.pixelSize(data))
        #expect(size.0 == 256 && size.1 == 256)
        let file = dir.appendingPathComponent(LAAOwnerProfileStore.avatarFileName)
        #expect(try Data(contentsOf: file) == data)

        let other = makeStore(dir)
        #expect(other.avatarData == data)
        #expect(other.avatarImage != nil)

        store.removeAvatar()
        #expect(store.avatarData == nil && store.avatarImage == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        other.reload()
        #expect(other.avatarData == nil)

        #expect(throws: LAAOwnerProfileError.unreadableImage) {
            try store.saveAvatar(imageData: Data("nope".utf8))
        }
        #expect(store.avatarData == nil)

        // Saving again after a removal works and the name survives both.
        store.saveDisplayName("Saya")
        try store.saveAvatar(imageData: Self.jpeg(width: 50, height: 50))
        #expect(store.avatarData != nil)
        let third = makeStore(dir)
        #expect(third.displayName == "Saya")
        #expect(third.avatarData != nil)
    }

    @Test func storageResolution() {
        let dir = Self.temporaryDirectory()
        let explicit = LAAOwnerProfileStore.resolveLocation(appGroup: LAAOwnerProfileStore.defaultAppGroup, directory: dir)
        #expect(explicit.url == dir)
        #expect(!explicit.shared)
        #expect(!explicit.seedsFromBridge)
        #expect(explicit.keychainGroup == nil)
        #if os(macOS)
        // The test runner has no App Group entitlement: the owner's own folder, shared by non-sandboxed apps.
        let mac = LAAOwnerProfileStore.resolveLocation(appGroup: LAAOwnerProfileStore.defaultAppGroup, directory: nil)
        #expect(mac.url.path.hasSuffix("Library/Application Support/LAA/OwnerProfile"))
        #expect(mac.shared)
        #expect(mac.keychainGroup == nil)
        #endif
    }
}
