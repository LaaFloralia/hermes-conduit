import Foundation
import Observation
import SwiftUI
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(Security)
import Security
#endif

/// The owner's own name and picture, shared by every LAA app (D-30, 2026-11-28: "右下のタブバーのアイコンと名称は
/// アプリのやつでなくて自分のユーザー名とアイコン"). One setting in any app shows in all of them:
/// - When the App Group (`group.com.laa-inc.shared`) is provisioned, files live in its shared container.
/// - Otherwise on iOS/watchOS, values live in the team's shared Keychain Access Group
///   (`PAW258GB42.com.laa-inc.shared`, covered by every team provisioning profile without Portal App Group setup).
/// - On macOS, non-sandboxed apps share `~/Library/Application Support/LAA/OwnerProfile`; sandboxed apps without
///   an App Group fall back to their own container.
/// A Darwin notification tells the other running apps to re-read.
/// The kit bundles no picture and does no networking; Hortensia may mirror the picture to Bridge itself
/// (`LAAOwnerProfileSettingsCard(onAvatarChange:)`).
@MainActor
@Observable
public final class LAAOwnerProfileStore {
    public nonisolated static let defaultAppGroup = "group.com.laa-inc.shared"
    public nonisolated static let defaultKeychainAccessGroup = "PAW258GB42.com.laa-inc.shared"
    public nonisolated static let defaultDisplayName = "LAA"
    /// Posted (Darwin, cross-process) after any app changes the profile.
    public nonisolated static let changedNotification = "com.laa-inc.shared.owner-profile.changed"
    public nonisolated static let avatarFileName = "owner-avatar.jpg"
    public nonisolated static let profileFileName = "owner-profile.json"
    private nonisolated static let keychainService = "com.laa-inc.shared.owner-profile"
    private nonisolated static let keychainProfileAccount = "profile"
    private nonisolated static let keychainAvatarAccount = "avatar"

    public static let shared = LAAOwnerProfileStore()

    /// Trimmed; never empty (falls back to "LAA").
    public private(set) var displayName: String = LAAOwnerProfileStore.defaultDisplayName
    /// The prepared square JPEG (≤ 256 px), or nil for the initial.
    public private(set) var avatarData: Data?
    /// `avatarData` decoded once.
    public private(set) var avatarImage: Image?

    /// The first letter of `displayName`, upper-cased ("L" by default).
    public var initial: String { Self.initial(of: displayName) }
    /// True when the name is the owner's own, not the default.
    public var isCustomName: Bool { displayName != Self.defaultDisplayName }

    /// Whether other LAA apps read the same storage (false: this app keeps its own copy).
    public let isSharedContainer: Bool
    /// Where the profile lives, for the settings footnote and diagnostics.
    public let storageLocationDescription: String
    /// The folder holding `owner-avatar.jpg` and `owner-profile.json` when file-backed.
    public let directory: URL

    @ObservationIgnored private let keychainGroup: String?
    @ObservationIgnored private let seedsFromBridge: Bool
    @ObservationIgnored private var avatarRemoved = false
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - appGroup: the shared App Group; nil skips the App Group container.
    ///   - keychainAccessGroup: shared team Keychain Access Group used on iOS/watchOS when the App Group is absent.
    ///   - directory: an explicit folder (tests, previews); overrides shared storage and is never shared.
    public init(appGroup: String? = LAAOwnerProfileStore.defaultAppGroup,
                keychainAccessGroup: String? = LAAOwnerProfileStore.defaultKeychainAccessGroup,
                directory: URL? = nil) {
        let location = Self.resolveLocation(appGroup: appGroup,
                                            keychainAccessGroup: keychainAccessGroup,
                                            directory: directory)
        self.directory = location.url
        self.keychainGroup = location.keychainGroup
        self.isSharedContainer = location.shared
        self.storageLocationDescription = location.description
        self.seedsFromBridge = directory == nil && location.seedsFromBridge
        load()
        observe()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Writing

    /// Saves the name (trimmed). An empty name, or "LAA", resets to the default.
    public func saveDisplayName(_ name: String) {
        let resolved = Self.resolvedName(name)
        guard resolved != displayName else { return }
        displayName = resolved
        writeProfile()
        Self.postChange()
    }

    /// Crops the image to a centred square (≤ 256 px), stores it as JPEG and tells the other apps.
    public func saveAvatar(imageData: Data) throws {
        guard let prepared = Self.preparedAvatarJPEG(from: imageData) else { throw LAAOwnerProfileError.unreadableImage }
        if let group = keychainGroup {
            let status = Self.keychainWrite(prepared, account: Self.keychainAvatarAccount, group: group)
            guard status == errSecSuccess else {
                throw LAAOwnerProfileError.saveFailed("Keychain status \(status)")
            }
        } else {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try prepared.write(to: avatarURL, options: .atomic)
            } catch {
                throw LAAOwnerProfileError.saveFailed(error.localizedDescription)
            }
        }
        avatarRemoved = false
        writeProfile()
        apply(avatar: prepared)
        Self.postChange()
    }

    /// Back to the initial. Remembered, so a Mac does not re-seed the old picture from Bridge.
    public func removeAvatar() {
        if let group = keychainGroup {
            Self.keychainDelete(account: Self.keychainAvatarAccount, group: group)
        } else {
            try? FileManager.default.removeItem(at: avatarURL)
        }
        avatarRemoved = true
        writeProfile()
        apply(avatar: nil)
        Self.postChange()
    }

    /// Re-reads the files (another app changed them, the app came to the foreground).
    public func reload() { load() }

    // MARK: Pure helpers

    public nonisolated static func resolvedName(_ name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultDisplayName : trimmed
    }

    public nonisolated static func initial(of name: String) -> String {
        guard let first = resolvedName(name).first else { return "L" }
        let upper = String(first).uppercased()
        return upper.first.map(String.init) ?? "L"
    }

    /// The picture as stored: EXIF orientation applied, centre square crop, at most `maxPixelSize` per side,
    /// JPEG quality 0.85. ImageIO/CoreGraphics only, so iOS, macOS and watchOS produce the same bytes. Nil when
    /// the data is not an image.
    public nonisolated static func preparedAvatarJPEG(from data: Data, maxPixelSize: Int = 256) -> Data? {
        #if canImport(ImageIO)
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawW = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let rawH = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              rawW > 0, rawH > 0 else { return nil }
        // Decode just large enough that the short side still covers the target.
        let long = max(rawW, rawH), short = min(rawW, rawH)
        let decodeMax = min(long, (Double(maxPixelSize) * long / short).rounded(.up))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(decodeMax),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let w = decoded.width, h = decoded.height
        let side = min(w, h)
        guard side > 0,
              let square = decoded.cropping(to: CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side))
        else { return nil }
        let target = min(side, maxPixelSize)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // JPEG has no alpha: transparent pictures sit on white, not black.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: target, height: target))
        context.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let output = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, output,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
        #else
        return nil
        #endif
    }

    /// Decodes stored avatar bytes into an Image (nil when unreadable).
    public nonisolated static func image(from data: Data) -> Image? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Image(decorative: cg, scale: 1)
        #else
        return nil
        #endif
    }

    // MARK: Files

    private var avatarURL: URL { directory.appendingPathComponent(Self.avatarFileName) }
    private var profileURL: URL { directory.appendingPathComponent(Self.profileFileName) }

    private struct ProfileFile: Codable {
        var displayName: String?
        var avatarRemoved: Bool?
    }

    private func load() {
        var file = ProfileFile()
        let rawProfile: Data? = if let group = keychainGroup {
            Self.keychainRead(account: Self.keychainProfileAccount, group: group)
        } else {
            try? Data(contentsOf: profileURL)
        }
        if let data = rawProfile,
           let decoded = try? JSONDecoder().decode(ProfileFile.self, from: data) { file = decoded }
        let name = Self.resolvedName(file.displayName)
        if name != displayName { displayName = name }
        avatarRemoved = file.avatarRemoved ?? false

        var avatar: Data? = if let group = keychainGroup {
            Self.keychainRead(account: Self.keychainAvatarAccount, group: group)
        } else {
            try? Data(contentsOf: avatarURL)
        }
        if avatar == nil, seedsFromBridge, !avatarRemoved { avatar = Self.bridgeSeed() }
        if avatar != avatarData { apply(avatar: avatar) }
    }

    private func apply(avatar: Data?) {
        let image = avatar.flatMap(Self.image(from:))
        avatarData = image == nil ? nil : avatar
        avatarImage = image
    }

    private func writeProfile() {
        let file = ProfileFile(displayName: displayName == Self.defaultDisplayName ? nil : displayName,
                               avatarRemoved: avatarRemoved ? true : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(file) else { return }
        if let group = keychainGroup {
            _ = Self.keychainWrite(data, account: Self.keychainProfileAccount, group: group)
        } else {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: profileURL, options: .atomic)
        }
    }

    // MARK: Shared Keychain (iOS / watchOS fallback when App Group is absent)

    private nonisolated static func canUseKeychainGroup(_ group: String) -> Bool {
        #if canImport(Security) && !os(macOS)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainProfileAccount,
            kSecAttrAccessGroup: group,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecItemNotFound
        #else
        return false
        #endif
    }

    private nonisolated static func keychainRead(account: String, group: String) -> Data? {
        #if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: group,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
        #else
        return nil
        #endif
    }

    private nonisolated static func keychainWrite(_ data: Data, account: String, group: String) -> OSStatus {
        #if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: group,
        ]
        let update: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated != errSecItemNotFound { return updated }
        var insert = query
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil)
        #else
        return errSecUnimplemented
        #endif
    }

    private nonisolated static func keychainDelete(account: String, group: String) {
        #if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: group,
        ]
        _ = SecItemDelete(query as CFDictionary)
        #endif
    }

    /// macOS only: Bridge's copy of the owner's picture (`~/.local/state/laa-bridge/owner-avatar.img`), read
    /// without touching it, until the owner sets one through the kit.
    private nonisolated static func bridgeSeed() -> Data? {
        #if os(macOS)
        let url = realHome.appendingPathComponent(".local/state/laa-bridge/owner-avatar.img")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return preparedAvatarJPEG(from: data)
        #else
        return nil
        #endif
    }

    // MARK: Location

    struct Location {
        let url: URL
        let shared: Bool
        let description: String
        let seedsFromBridge: Bool
        let keychainGroup: String?
    }

    nonisolated static func resolveLocation(appGroup: String?,
                                            keychainAccessGroup: String? = defaultKeychainAccessGroup,
                                            directory: URL?) -> Location {
        if let directory {
            return Location(url: directory, shared: false, description: directory.path,
                            seedsFromBridge: false, keychainGroup: nil)
        }
        let fm = FileManager.default
        #if os(macOS)
        // Only an entitled app opens the group container: an unentitled one would trigger macOS's "access data
        // from other apps" prompt.
        if let appGroup, hasAppGroupEntitlement(appGroup),
           let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return Location(url: container.appendingPathComponent("OwnerProfile", isDirectory: true), shared: true,
                            description: "App Group \(appGroup)", seedsFromBridge: true, keychainGroup: nil)
        }
        // Non-sandboxed Mac apps share the owner's own folder; a sandboxed one only reaches its container.
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let base = sandboxed ? (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? realHome)
                             : realHome.appendingPathComponent("Library/Application Support", isDirectory: true)
        let url = base.appendingPathComponent("LAA/OwnerProfile", isDirectory: true)
        return Location(url: url, shared: !sandboxed,
                        description: sandboxed ? "This app only (\(url.path))" : url.path,
                        seedsFromBridge: !sandboxed, keychainGroup: nil)
        #else
        if let appGroup, let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return Location(url: container.appendingPathComponent("OwnerProfile", isDirectory: true), shared: true,
                            description: "App Group \(appGroup)", seedsFromBridge: false, keychainGroup: nil)
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let url = support.appendingPathComponent("LAAOwnerProfile", isDirectory: true)
        if let keychainAccessGroup, canUseKeychainGroup(keychainAccessGroup) {
            return Location(url: url, shared: true,
                            description: "Keychain Group \(keychainAccessGroup)",
                            seedsFromBridge: false, keychainGroup: keychainAccessGroup)
        }
        return Location(url: url, shared: false, description: "This app only (shared storage unavailable)",
                        seedsFromBridge: false, keychainGroup: nil)
        #endif
    }

    #if os(macOS)
    private nonisolated static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private nonisolated static func hasAppGroupEntitlement(_ group: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String] else { return false }
        return groups.contains(group)
    }
    #endif

    // MARK: Live sync

    private nonisolated static let localChange = Notification.Name("LAAOwnerProfileStore.changed")

    /// One Darwin observer per process, forwarded to the local center (the C callback cannot capture a store).
    private static let darwinRegistration: Void = {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in NotificationCenter.default.post(name: LAAOwnerProfileStore.localChange, object: nil) },
            changedNotification as CFString, nil, .deliverImmediately)
    }()

    private nonisolated static func postChange() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(changedNotification as CFString), nil, nil, true)
    }

    private func observe() {
        _ = Self.darwinRegistration
        let center = NotificationCenter.default
        var names = [Self.localChange]
        #if os(iOS) || os(tvOS) || os(visionOS)
        names.append(UIApplication.willEnterForegroundNotification)
        #elseif os(macOS)
        names.append(NSApplication.didBecomeActiveNotification)
        #endif
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }
}

public enum LAAOwnerProfileError: LocalizedError, Equatable {
    case unreadableImage
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableImage: "This image could not be read."
        case .saveFailed(let reason): "The picture could not be saved. \(reason)"
        }
    }
}
