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
        // White text has 4.5:1 contrast at luminance <= 0.18333. A
        // neutral sRGB channel of this value has exactly that luminance.
        let limit = 1.055 * pow((1.05 / 4.5 - 0.05), 1 / 2.4) - 0.055
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
    static let shared = LAABackgroundStore()
    @Published private(set) var revision = 0
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LAAConversationBackgrounds", isDirectory: true)
    }

    func setting(for key: LAABackgroundKey) -> LAABackground {
        guard let data = try? Data(contentsOf: settingURL(key)),
              var value = try? JSONDecoder().decode(LAABackground.self, from: data) else { return LAABackground() }
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var normalized = value
        normalized.normalize()
        if normalized.kind == .photo && image(named: normalized.photoID) == nil { throw LAABackgroundError.missingPhoto }
        try JSONEncoder().encode(normalized).write(to: settingURL(key), options: .atomic)
        revision += 1
    }

    func savePhoto(_ data: Data, for key: LAABackgroundKey, dim: Double, blur: Double) throws {
        let photo = try LAABackgroundPhoto.prepare(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photoID = SHA256.hash(data: photo.data).map { String(format: "%02x", $0) }.joined()
        try photo.data.write(to: directory.appendingPathComponent(photoID + ".jpg"), options: .atomic)
        try save(LAABackground(kind: .photo, dim: dim, blur: blur, brightestComponent: photo.maxComponent, photoID: photoID), for: key)
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
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw LAABackgroundError.invalidPhoto
        }
        context.draw(saved, in: CGRect(x: 0, y: 0, width: width, height: height))
        var brightest: UInt8 = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            brightest = max(brightest, pixels[index], pixels[index + 1], pixels[index + 2])
        }
        return (jpeg, Double(brightest) / 255)
    }
}
#endif
