// sRGB RGBA, not compressed PNG bytes. Outside the common rectangle, a pixel
// counts as changed if it exists in either image (denominator is their union).
import CoreGraphics
import Foundation
import ImageIO

struct Raster {
    let width: Int
    let height: Int
    let pixels: [UInt32]

    init(_ path: String) throws {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path])
        }
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 10_000, h <= 10_000, w * h <= 20_000_000 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path])
        }
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var rgba = [UInt32](repeating: 0, count: w * h)
        let drawn = rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space, bitmapInfo: bitmap) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path]) }
        width = w; height = h; pixels = rgba
    }

    func changedRatio(_ other: Self) -> Double {
        let w = min(width, other.width), h = min(height, other.height)
        let union = width * height + other.width * other.height - w * h
        var changed = union - w * h
        for y in 0..<h {
            for x in 0..<w where pixels[y * width + x] != other.pixels[y * other.width + x] {
                changed += 1
            }
        }
        return Double(changed) / Double(union)
    }
}

do {
    let pairs = try JSONDecoder().decode([[String]].self, from: FileHandle.standardInput.readDataToEndOfFile())
    let output = try pairs.map { pair in
        guard pair.count == 2 else { throw CocoaError(.coderInvalidValue) }
        return try Raster(pair[0]).changedRatio(Raster(pair[1]))
    }
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(output))
} catch {
    try FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
    exit(1)
}
