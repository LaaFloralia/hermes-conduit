//
//  ProfileGlowColors.swift
//  Conduit
//
//  The backdrop's glow takes each profile's own color: the one picked for it
//  in the profile picker, else the main color of its photo. Two profiles
//  whose photos share a main color would glow alike, so the later one in the
//  profile order falls back to its photo's second, then third color. A
//  profile with no photo (or a photo with no real color in it) keeps the
//  color its bot has in Hermes, or the gold accent.
//

import CoreGraphics
import SwiftUI
import UIKit

/// One glow color, kept as `#rrggbb`.
struct ProfileGlowRGB: Equatable, Hashable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    init?(hex: String) {
        guard let rgb = BotAvatarColor.rgb(from: hex) else { return nil }
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// A color from the system color picker, converted to sRGB (the picker
    /// can hand back Display P3). Nil when it has no RGB form.
    init?(_ color: UIColor) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3
        else { return nil }
        self.init(red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]))
    }

    var hex: String {
        String(format: "#%02x%02x%02x", Self.byte(red), Self.byte(green), Self.byte(blue))
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Hue in degrees (0..<360), saturation and brightness in 0...1.
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let delta = high - low
        guard delta > 0 else { return (0, 0, high) }
        var hue: Double
        if high == red {
            hue = (green - blue) / delta
        } else if high == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, delta / high, high)
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let chroma = brightness * saturation
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let rgb: (Double, Double, Double)
        switch h {
        case ..<1: rgb = (chroma, x, 0)
        case ..<2: rgb = (x, chroma, 0)
        case ..<3: rgb = (0, chroma, x)
        case ..<4: rgb = (0, x, chroma)
        case ..<5: rgb = (x, 0, chroma)
        default: rgb = (chroma, 0, x)
        }
        let m = brightness - chroma
        self.init(red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m)
    }

    /// Whether two glows would read as the same color: hues closer than 30°, or
    /// two greys of about the same lightness.
    func looksLike(_ other: ProfileGlowRGB) -> Bool {
        let a = hsb, b = other.hsb
        let aGrey = a.saturation < 0.15, bGrey = b.saturation < 0.15
        if aGrey || bGrey {
            return aGrey && bGrey && abs(a.brightness - b.brightness) < 0.2
        }
        let distance = abs(a.hue - b.hue)
        return min(distance, 360 - distance) < ProfileGlowPalette.distinctHueDegrees
    }

    private static func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }
}

/// A photo's main colors, most prominent first.
enum ProfileGlowPalette {
    /// The main, second and third color: as far down as the fallback goes.
    static let maxColors = 3
    /// Colors closer than this in hue count as one color.
    static let distinctHueDegrees: Double = 30
    /// The photo is scaled down to this many pixels a side before counting.
    static let sampleSide = 32
    /// Pixels this grey, dark or faint carry no color worth a glow.
    static let minimumSaturation = 0.2
    static let minimumBrightness = 0.2
    /// A color must cover this share of the photo's colorful pixels, so a
    /// few stray pixels never become a profile's glow.
    static let minimumShare = 0.04

    static func colors(from image: CGImage) -> [ProfileGlowRGB] {
        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }

        // Hue bins of 15°: each keeps its weight and weighted color sum.
        let binCount = 24
        var weights = [Double](repeating: 0, count: binCount)
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: binCount)
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha >= 0.5 else { continue }
            let pixel = ProfileGlowRGB(
                red: Double(pixels[index]) / 255 / alpha,
                green: Double(pixels[index + 1]) / 255 / alpha,
                blue: Double(pixels[index + 2]) / 255 / alpha
            )
            let hsb = pixel.hsb
            guard hsb.saturation >= minimumSaturation, hsb.brightness >= minimumBrightness else { continue }
            // Vivid pixels count for more than washed-out ones of the same hue.
            let weight = hsb.saturation * hsb.brightness
            let bin = min(Int(hsb.hue / (360 / Double(binCount))), binCount - 1)
            weights[bin] += weight
            sums[bin].0 += pixel.red * weight
            sums[bin].1 += pixel.green * weight
            sums[bin].2 += pixel.blue * weight
            total += weight
        }
        guard total > 0 else { return [] }

        var picked: [ProfileGlowRGB] = []
        for bin in weights.indices.sorted(by: { weights[$0] > weights[$1] }) {
            guard picked.count < maxColors, weights[bin] / total >= minimumShare else { break }
            let weight = weights[bin]
            let mean = ProfileGlowRGB(red: sums[bin].0 / weight, green: sums[bin].1 / weight, blue: sums[bin].2 / weight)
            let glow = glowable(mean)
            if picked.contains(where: { $0.looksLike(glow) }) { continue }
            picked.append(glow)
        }
        return picked
    }

    /// A photo's colors are often dark or muted; a glow drawn from them
    /// would be mud. Keep the hue, lift the color to a glow's strength.
    static func glowable(_ color: ProfileGlowRGB) -> ProfileGlowRGB {
        let hsb = color.hsb
        return ProfileGlowRGB(
            hue: hsb.hue,
            saturation: max(hsb.saturation, 0.45),
            brightness: max(hsb.brightness, 0.75)
        )
    }
}

enum ProfileGlowAssignment {
    /// Each profile's glow. Picked colors are claimed first; then, in
    /// profile order, each photo's main color unless an earlier profile
    /// already glows like it, then its second and third. When all of them
    /// are taken the main color is used anyway. Profiles with neither a pick
    /// nor a photo color are left out, as are picks for unlisted profiles.
    static func assign(
        order: [String],
        palettes: [String: [ProfileGlowRGB]],
        picked: [String: ProfileGlowRGB]
    ) -> [String: ProfileGlowRGB] {
        // A pick for a profile no longer listed (deleted or renamed) is
        // neither returned nor claimed.
        var result = picked.filter { order.contains($0.key) }
        var taken = order.compactMap { result[$0] }
        for profile in order where result[profile] == nil {
            guard let palette = palettes[profile], let main = palette.first else { continue }
            let choice = palette.first { candidate in !taken.contains { $0.looksLike(candidate) } } ?? main
            result[profile] = choice
            taken.append(choice)
        }
        return result
    }
}

/// What the glow colors were worked out from, so they are only worked out
/// again when it changes.
struct ProfileGlowCacheKey: Equatable {
    let order: [String]
    let avatarRevision: Int
    let picks: [String: String]
}
