#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// The shared transcript (LAATranscript): one owner bubble, bubble-less
/// staff prose and the thinking line, rendered in a real window at the
/// owner's 440 pt width so the drawn result is judged, not the component.
@MainActor
final class LAAChatTranscriptTests: XCTestCase {
    private let width: CGFloat = 440

    func testMetricsFollowTheTranscriptContract() {
        XCTAssertEqual(LAATranscriptMetrics.ownerBubbleRadius, 18)
        #if !targetEnvironment(macCatalyst)
        XCTAssertEqual(LAATranscriptMetrics.ownerBubblePaddingV, 12)
        XCTAssertEqual(LAATranscriptMetrics.ownerBubblePaddingH, 16)
        XCTAssertEqual(LAATranscriptMetrics.avatar, 24)
        XCTAssertEqual(LAATranscriptMetrics.speakerToProse, 8)
        XCTAssertEqual(LAATranscriptMetrics.turnGap, 24)
        XCTAssertEqual(LAATranscriptMetrics.rowGap, 12)
        XCTAssertEqual(LAATranscriptMetrics.ownerBubbleMaxWidth(column: 400), 312)
        XCTAssertNil(LAATranscriptMetrics.proseMeasure)
        #else
        XCTAssertEqual(LAATranscriptMetrics.ownerBubbleMaxWidth(column: 2000), 560 / 0.77, accuracy: 0.5)
        XCTAssertEqual(LAATranscriptMetrics.proseMeasure ?? 0, 680 / 0.77, accuracy: 0.5)
        #endif
    }

    func testOwnerHasTheOnlyBubbleAndStaffProseSitsOnPaper() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let image = try render(style: style, height: 520) {
                VStack(spacing: LAATranscriptMetrics.rowGap) {
                    LAATranscriptOwnerTurn(timestamp: nil) {
                        Text(verbatim: "今日の優先順を三つに絞ってください。")
                            .font(.system(size: 17)).foregroundStyle(LAAColor.text)
                            .laaTranscriptOwnerBubble()
                    }
                    LAATranscriptAgentTurn(name: "Monet", role: "Secretary", timestamp: nil) {
                        Circle().fill(LAAColor.link)
                    } content: {
                        Text(verbatim: String(repeating: "まず午前に決めることを一つ。Then the rest. ", count: 4))
                            .font(.system(size: 17)).foregroundStyle(LAAColor.text)
                            .accessibilityIdentifier("transcript.staff.prose")
                    }
                    LAAThoughtLine(text: "Thinking", isLive: false)
                }
                .padding(.horizontal, 20)
            }
            let wash = color(LAAColor.subtleSurface, style)
            let paper = color(LAAColor.background, style)
            let surface = color(LAAColor.surface, style)
            // The owner's bubble: a wide run of `wash` on the trailing half.
            let ownerRows = rows(in: image, matching: wash, minRun: 120)
            XCTAssertFalse(ownerRows.isEmpty, "\(style.rawValue): the owner's wash bubble must be drawn")
            let ownerTop = ownerRows.min() ?? 0, ownerBottom = ownerRows.max() ?? 0
            // Below the owner's bubble no row has a bubble ground: staff
            // prose is set on the paper, with no `surface` card.
            let below = Int(ownerBottom) + 8
            XCTAssertTrue(rows(in: image, matching: wash, minRun: 120).allSatisfy { $0 < CGFloat(below) },
                          "\(style.rawValue): only the owner's turn carries a bubble")
            XCTAssertTrue(rows(in: image, matching: surface, minRun: 120).filter { $0 > CGFloat(below) }.isEmpty
                          || surface == paper,
                          "\(style.rawValue): staff prose must not sit on a surface card")
            XCTAssertGreaterThan(ownerBottom - ownerTop, 30)
            attach(image, name: "transcript-\(style == .dark ? "dark" : "light")")
        }
    }

    func testOwnerBubbleTakesAtMostItsShareOfTheColumn() throws {
        let image = try render(style: .light, height: 300) {
            LAATranscriptOwnerTurn(timestamp: nil) {
                Text(verbatim: String(repeating: "長い社長の発言が折り返す。", count: 12))
                    .font(.system(size: 17))
                    .laaTranscriptOwnerBubble()
            }
            .padding(.horizontal, 20)
        }
        let span = try XCTUnwrap(widestRun(in: image, matching: color(LAAColor.subtleSurface, .light)))
        XCTAssertLessThanOrEqual(span.upperBound - span.lowerBound, 400 * 0.78 + 1)
        XCTAssertEqual(width - span.upperBound, 20, accuracy: 2, "The bubble trails at the margin")
    }

    // MARK: - Rendering

    private func render<V: View>(style: UIUserInterfaceStyle, height: CGFloat, @ViewBuilder _ content: () -> V) throws -> UIImage {
        // As in the transcript's lazy stack: each row takes the height it needs.
        let root = content()
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, height: height, alignment: .top)
            .background(LAAColor.background)
            .environment(\.colorScheme, style == .dark ? .dark : .light)
        let host = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<6 {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func color(_ color: Color, _ style: UIUserInterfaceStyle) -> [Int] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b].map { Int(($0 * 255).rounded()) }
    }

    private func pixels(_ image: UIImage) -> (bytes: [UInt8], width: Int, height: Int) {
        let cg = image.cgImage!
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (bytes, w, h)
    }

    /// Rows that hold a horizontal run of `expected` at least `minRun` wide.
    private func rows(in image: UIImage, matching expected: [Int], minRun: Int) -> [CGFloat] {
        let (bytes, w, h) = pixels(image)
        var found: [CGFloat] = []
        for y in 0..<h {
            var run = 0, best = 0
            for x in 0..<w {
                let o = (y * w + x) * 4
                if (0..<3).allSatisfy({ abs(Int(bytes[o + $0]) - expected[$0]) <= 3 }) { run += 1; best = max(best, run) } else { run = 0 }
            }
            if best >= minRun { found.append(CGFloat(y)) }
        }
        return found
    }

    private func widestRun(in image: UIImage, matching expected: [Int]) -> Range<CGFloat>? {
        let (bytes, w, h) = pixels(image)
        var best: Range<Int>?
        for y in 0..<h {
            var start: Int?
            for x in 0...w {
                let o = (y * w + min(x, w - 1)) * 4
                let match = x < w && (0..<3).allSatisfy { abs(Int(bytes[o + $0]) - expected[$0]) <= 3 }
                if match, start == nil { start = x }
                if !match, let s = start {
                    if (x - s) > (best.map { $0.upperBound - $0.lowerBound } ?? 0) { best = s..<x }
                    start = nil
                }
            }
        }
        return best.map { CGFloat($0.lowerBound)..<CGFloat($0.upperBound) }
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
