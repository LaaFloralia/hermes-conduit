#if LAA_BUILD
import Combine
import CryptoKit
import Foundation
import ImageIO
import UIKit

struct LAABackgroundKey: Codable, Hashable {
    enum Surface: String, Codable { case chat, group }
    let dashboard: UUID
    let profile: String
    let conversation: String
    let surface: Surface

    var fileID: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct LAABackground: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case paper, tealNight, ink, photo }
    var kind: Kind = .paper
    var dim: Double = 0
    var blur: Double = 0
    /// Maximum encoded RGB component in the saved photo, in sRGB. It is a
    /// conservative bound on every pixel, including bright coloured pixels.
    var brightestComponent: Double = 1
    var photoID: String? = nil

    var safeDim: Double {
        kind == .photo ? max(dim.clamped(to: 0...0.6), Self.minimumDim(brightestComponent)) : 0
    }

    static func minimumDim(_ maxComponent: Double) -> Double {
        let component = maxComponent.clamped(to: 0...1)
        guard component > 0 else { return 0 }
        // Leave room for 8-bit rounding while meeting the 4.5:1 floor.
        let limit = 1.055 * pow((1.05 / 4.6 - 0.05), 1 / 2.4) - 0.055
        return max(0, min(1, 1 - limit / component))
    }

    mutating func normalize() {
        dim = dim.isFinite ? dim.clamped(to: 0...0.6) : 0
        blur = blur.isFinite ? blur.clamped(to: 0...20) : 0
        brightestComponent = brightestComponent.isFinite ? brightestComponent.clamped(to: 0...1) : 1
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(range.upperBound, max(range.lowerBound, self)) }
}

/// Each setting and its local photo belong to a single dashboard/profile/id.
/// The hash prevents a server-provided id from becoming a filesystem path.
@MainActor
final class LAABackgroundStore: ObservableObject {
    private struct Record: Codable {
        let key: LAABackgroundKey
        let background: LAABackground
    }
    static let shared = LAABackgroundStore()
    @Published private(set) var revision = 0
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LAAConversationBackgrounds", isDirectory: true)
        if FileManager.default.fileExists(atPath: self.directory.path) {
            try? excludeFromBackup()
        }
    }

    func setting(for key: LAABackgroundKey) -> LAABackground {
        guard let data = try? Data(contentsOf: settingURL(key)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.key == key else { return LAABackground() }
        var value = record.background
        value.normalize()
        if value.kind == .photo && image(named: value.photoID) == nil { return LAABackground() }
        return value
    }

    func image(for key: LAABackgroundKey) -> UIImage? { image(named: setting(for: key).photoID) }

    private func image(named id: String?) -> UIImage? {
        guard let id, id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }),
              let data = try? Data(contentsOf: directory.appendingPathComponent(id + ".jpg")) else { return nil }
        return UIImage(data: data)
    }

    func save(_ value: LAABackground, for key: LAABackgroundKey) throws {
        try ensureDirectory()
        var normalized = value
        normalized.normalize()
        if normalized.kind != .photo { normalized.photoID = nil }
        if normalized.kind == .photo && image(named: normalized.photoID) == nil { throw LAABackgroundError.missingPhoto }
        try JSONEncoder().encode(Record(key: key, background: normalized)).write(to: settingURL(key), options: .atomic)
        revision += 1
        try removeUnreferencedPhotos()
    }

    func savePhoto(_ data: Data, for key: LAABackgroundKey, dim: Double, blur: Double) throws {
        let photo = try LAABackgroundPhoto.prepare(data)
        try ensureDirectory()
        let photoID = SHA256.hash(data: photo.data).map { String(format: "%02x", $0) }.joined()
        try photo.data.write(to: directory.appendingPathComponent(photoID + ".jpg"), options: .atomic)
        do {
            try save(LAABackground(kind: .photo, dim: dim, blur: blur, brightestComponent: photo.maxComponent, photoID: photoID), for: key)
        } catch {
            try? removeUnreferencedPhotos()
            throw error
        }
    }

    func removeAll(dashboardID: UUID) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        defer { revision += 1 }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.key.dashboard == dashboardID else { continue }
            try FileManager.default.removeItem(at: url)
        }
        try removeUnreferencedPhotos()
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup()
    }

    private func excludeFromBackup() throws {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func removeUnreferencedPhotos() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var references = Set<String>()
        for url in files where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            guard let record = try? JSONDecoder().decode(Record.self, from: data) else { return }
            let value = record.background
            if value.kind == .photo, let id = value.photoID { references.insert(id) }
        }
        for url in files where url.pathExtension == "jpg" {
            let id = url.deletingPathExtension().lastPathComponent
            guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }),
                  !references.contains(id) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func settingURL(_ key: LAABackgroundKey) -> URL { directory.appendingPathComponent(key.fileID + ".json") }
}

enum LAABackgroundError: Error { case invalidPhoto, missingPhoto }

enum LAABackgroundPhoto {
    static func prepare(_ data: Data) throws -> (data: Data, maxComponent: Double) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600,
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.84),
              let saved = UIImage(data: jpeg)?.cgImage else { throw LAABackgroundError.invalidPhoto }
        let width = saved.width, height = saved.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw LAABackgroundError.invalidPhoto }
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw LAABackgroundError.invalidPhoto
            }
            context.draw(saved, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var brightest: UInt8 = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            brightest = max(brightest, pixels[index], pixels[index + 1], pixels[index + 2])
        }
        return (jpeg, Double(brightest) / 255)
    }
}
#endif
