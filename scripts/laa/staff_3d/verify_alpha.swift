// usage: swift verify_alpha.swift file.mov ...  -> prints JSON per file
import AVFoundation
import CoreImage
import Foundation
func check(_ path: String) async throws -> [String: Any] {
  let asset = AVURLAsset(url: URL(fileURLWithPath: path))
  let tracks = try await asset.loadTracks(withMediaType: .video)
  guard let t = tracks.first else { return ["file": path, "error": "no video"] }
  let fds = try await t.load(.formatDescriptions)
  let fd = fds.first!
  let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
  let hasAlphaFlag = (ext["ContainsAlphaChannel"] as? Bool) ?? false
  let codec = CMFormatDescriptionGetMediaSubType(fd)
  let fourcc = String(bytes: [24, 16, 8, 0].map { UInt8((codec >> $0) & 0xff) }, encoding: .ascii) ?? "?"
  let dur = try await asset.load(.duration).seconds
  let fps = try await t.load(.nominalFrameRate)
  let size = try await t.load(.naturalSize)
  // decode first frame with alpha and sample corner + centre alpha
  let reader = try AVAssetReader(asset: asset)
  let out = AVAssetReaderTrackOutput(track: t, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
  reader.add(out); reader.startReading()
  var corner = -1, centre = -1, frames = 0, minA = 255
  while let sb = out.copyNextSampleBuffer() {
    if frames == 0, let pb = CMSampleBufferGetImageBuffer(sb) {
      CVPixelBufferLockBaseAddress(pb, .readOnly)
      let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
      let bpr = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
      corner = Int(base[3]); centre = Int(base[(h / 2) * bpr + (w / 2) * 4 + 3])
      for y in stride(from: 0, to: h, by: 4) { for x in stride(from: 0, to: w, by: 4) { minA = min(minA, Int(base[y * bpr + x * 4 + 3])) } }
      CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    }
    frames += 1
  }
  return ["file": (path as NSString).lastPathComponent, "codec": fourcc, "containsAlphaChannel": hasAlphaFlag,
          "duration": dur, "fps": fps, "frames": frames, "size": "\(Int(size.width))x\(Int(size.height))",
          "alphaCorner": corner, "alphaCentre": centre, "alphaMin": minA]
}
var results: [[String: Any]] = []
for p in CommandLine.arguments.dropFirst() { results.append(try await check(p)) }
let d = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
print(String(data: d, encoding: .utf8)!)
