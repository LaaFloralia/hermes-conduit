#if LAA_BUILD && LAA_WIDGET_TEST && DEBUG
import SwiftUI
import UIKit
import WidgetKit
import XCTest
@testable import Conduit

/// The medium widget's Usage bars must be filled to the share they show, in
/// every rendering mode. On tinted and clear Home Screens (`accented`)
/// WidgetKit keeps only each view's opacity, and in `vibrant` (StandBy, the
/// lock screen, a Mac desktop in the background) only its brightness: an
/// opaque track then drew the same as the fill and every bar looked full
/// (owner, 2026-11-26). The capture is transparent, so its alpha channel is
/// what those modes show; full colour is read from the colours themselves.
@MainActor
final class LAAUsageBarRenderingTests: XCTestCase {
    private typealias F = LAAUsageFixtures
    private let now = LAAUsageFixtures.now
    private let scale: CGFloat = 3

    /// Claude 5h, Claude 7d, Fable, Google 5h, Google 7d: every one of 0, 1,
    /// 50, 99 and 100 in more than one row.
    private static let sets: [[Double]] = [
        [1, 50, 99, 100, 0],
        [99, 1, 50, 0, 100],
        [0, 100, 1, 99, 50],
    ]

    func testWidgetBarsTrackTheShareInEveryMode() throws {
        for (index, shares) in Self.sets.enumerated() {
            let entry = try entry(shares)
            XCTAssertEqual(entry.usage?.meters.map(\.amount), shares, "fixture \(index)")
            for size in [LAAUsageV2SnapshotTestsSizes.proMax, LAAUsageV2SnapshotTestsSizes.compact] {
                for mode in [WidgetRenderingMode.fullColor, .accented, .vibrant] {
                    for style in [UIUserInterfaceStyle.light, .dark] {
                        let name = "bar-\(index)-\(Int(size.width))-\(Self.modeName(mode))-\(style == .dark ? "dark" : "light")"
                        let image = try capture(entry, size: size, mode: mode, style: style, name: name)
                        let bars = Self.bars(in: image, mode: mode, style: style)
                        XCTAssertEqual(bars.count, 5, "\(name): bars found")
                        for (bar, share) in zip(bars, shares) {
                            // A nonzero share keeps a 2pt sliver; antialiasing adds a pixel.
                            let floor = share > 0 ? 2 * scale / CGFloat(bar.track) : 0
                            let expected = max(share / 100, Double(floor))
                            XCTAssertEqual(bar.share, expected, accuracy: 0.02, "\(name): row showing \(Int(share))%")
                        }
                    }
                }
            }
        }
    }

    func testPaintKeepsTrackAndFillApartOutsideFullColour() {
        for mode in [WidgetRenderingMode.accented, .vibrant] {
            let paint = LAAUsageMeterTrack.Paint(mode: mode, level: .normal)
            XCTAssertNotEqual(paint.track, paint.fill, "\(Self.modeName(mode))")
            XCTAssertLessThan(LAAUsageMeterTrack.Paint.tintedTrackOpacity, 0.5)
        }
        let full = LAAUsageMeterTrack.Paint(mode: .fullColor, level: .caution)
        XCTAssertEqual(full.track, LAAColor.separator)
        XCTAssertEqual(full.fill, LAAUsageMeterTrack.caution)
    }

    // MARK: Fixture

    private func entry(_ shares: [Double]) throws -> LAAEmployeeWidgetEntry {
        let rows: [[String: Any]] = [
            F.quota("claude", label: "Claude", windows: [F.window("Session", shares[0], minutes: 300, reset: 7200),
                                                         F.window("Weekly", shares[1], minutes: 10_080, reset: 4 * 86_400)],
                    fable: F.fable(shares[2])),
            F.google("sub2", active: true, fiveHour: shares[3], weekly: shares[4]),
        ]
        let usage = LAAWidgetUsageBuilder.make(items: try F.decode(rows), receivedAt: now)
        let snapshot = WidgetSnapshot(appLanguage: "ja", currentWorkspaceID: nil, workspaces: []).withUsage(usage)
        return LAAEmployeeWidgetEntry.make(employee: .monet, snapshot: snapshot, date: now)
    }

    // MARK: Measuring

    struct Bar { let track: Int; let filled: Int; var share: Double { Double(filled) / Double(track) } }

    /// The bars, top to bottom: pixel rows in the Usage column where one run
    /// of drawn pixels spans most of the column (text never does), measured
    /// on the middle row of each 4pt band.
    static func bars(in image: RGBAImage, mode: WidgetRenderingMode, style: UIUserInterfaceStyle) -> [Bar] {
        let track = RGBAImage.Pixel(LAAColor.separator, style: style)
        let left = image.width / 2
        var bands: [[Int]] = []
        for y in 0..<image.height {
            let run = longestRun(image, y: y, from: left)
            guard run.count > (image.width - left) / 2 else { continue }
            if let last = bands.last?.last, last == y - 1 { bands[bands.count - 1].append(y) } else { bands.append([y]) }
        }
        return bands.map { band in
            let y = band[band.count / 2]
            let run = longestRun(image, y: y, from: left)
            let filled: Int
            switch mode {
            case .fullColor:
                // A fill pixel is far from the track's colour.
                filled = run.prefix { distance(image.pixel($0, y), track) > 40 }.count
            default:
                filled = run.prefix { image.pixel($0, y).a > 200 }.count
            }
            return Bar(track: run.count, filled: filled)
        }
    }

    private static func longestRun(_ image: RGBAImage, y: Int, from left: Int) -> Range<Int> {
        var best = left..<left, start: Int?
        for x in left...image.width {
            let drawn = x < image.width && image.pixel(x, y).a > 20
            if drawn, start == nil { start = x }
            if !drawn, let s = start {
                if x - s > best.count { best = s..<x }
                start = nil
            }
        }
        return best
    }

    private static func distance(_ a: RGBAImage.Pixel, _ b: RGBAImage.Pixel) -> Int {
        abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))
    }

    private static func modeName(_ mode: WidgetRenderingMode) -> String {
        switch mode {
        case .accented: "tinted"
        case .vibrant: "vibrant"
        default: "full"
        }
    }

    // MARK: Capture

    struct RGBAImage {
        struct Pixel {
            let r, g, b, a: UInt8
            init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) { self.r = r; self.g = g; self.b = b; self.a = a }
            init(_ color: Color, style: UIUserInterfaceStyle) {
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                    .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                self.init(r: UInt8((red * 255).rounded()), g: UInt8((green * 255).rounded()),
                          b: UInt8((blue * 255).rounded()), a: 255)
            }
        }
        let width: Int, height: Int
        let bytes: [UInt8]
        func pixel(_ x: Int, _ y: Int) -> Pixel {
            let i = (y * width + x) * 4
            return Pixel(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2], a: bytes[i + 3])
        }
    }

    /// The widget with no container background, so only what it draws is opaque.
    private func capture(_ entry: LAAEmployeeWidgetEntry, size: CGSize, mode: WidgetRenderingMode,
                         style: UIUserInterfaceStyle, name: String) throws -> RGBAImage {
        let view = LAAEmployeeWidgetView(entry: entry, familyOverride: .systemMedium, renderingModeOverride: mode,
                                         renderedAtOverride: entry.date)
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(style == .dark ? .dark : .light)
            .ignoresSafeArea()
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previous = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.backgroundColor = .clear
        window.traitOverrides.userInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let directory = ProcessInfo.processInfo.environment["LAA_USAGE_SHOT_DIR"], !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? Self.preview(image, mode: mode, style: style)?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
        return RGBAImage(width: width, height: height, bytes: bytes)
    }

    /// What the owner sees: full colour on the widget's surface; tinted and
    /// vibrant as the alpha in white over a dark wallpaper tone.
    private static func preview(_ image: UIImage, mode: WidgetRenderingMode, style: UIUserInterfaceStyle) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: image.size)
            if mode == .fullColor {
                LAAColor.uiSurface(style).setFill()
                context.fill(rect)
                image.draw(in: rect)
            } else {
                UIColor(red: 0.16, green: 0.20, blue: 0.27, alpha: 1).setFill()
                context.fill(rect)
                // Alpha only: every drawn pixel white at its own opacity.
                image.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: rect)
            }
        }.pngData()
    }
}

/// The two medium sizes the v2 captures use.
enum LAAUsageV2SnapshotTestsSizes {
    static let proMax = CGSize(width: 364, height: 170)
    static let compact = CGSize(width: 329, height: 155)
}

private extension LAAColor {
    static func uiSurface(_ style: UIUserInterfaceStyle) -> UIColor {
        UIColor(LAAColor.surface).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }
}
#endif
