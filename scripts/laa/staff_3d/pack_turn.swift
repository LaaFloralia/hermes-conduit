// pack_turn.swift <frames dir> <out.heic> [quality]: pack RGBA PNG frames into one multi-image HEIC with alpha
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let names = try FileManager.default.contentsOfDirectory(atPath: a[1]).filter { $0.hasSuffix(".png") }.sorted()
let quality = a.count > 3 ? Double(a[3])! : 0.7
guard let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.heic.identifier as CFString, names.count, nil) else { fatalError("no HEIC encoder") }
for n in names {
    let url = URL(fileURLWithPath: a[1]).appendingPathComponent(n)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError(n) }
    CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
}
guard CGImageDestinationFinalize(out) else { fatalError("finalize") }
print(names.count, "frames")
