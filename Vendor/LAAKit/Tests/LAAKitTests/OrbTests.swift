import LAATokens
import SwiftUI
import Testing
@testable import LAAKit

struct OrbTests {
    @Test func stateMapsToSeededParticleCountAndVoice() {
        let idle = makeField(LAAOrbMoment.still(state: .idle))
        let thinking = makeField(LAAOrbMoment.still(state: .thinking))
        let tool = makeField(LAAOrbMoment.still(state: .tool))
        #expect(thinking.litCount == 2538)
        #expect(idle.litCount < thinking.litCount)
        #expect(idle.litCount == makeField(LAAOrbMoment.still(state: .idle)).litCount)
        #expect(paths(tool) == paths(thinking))
        #expect(LAAOrbMoment.input(state: .thinking, level: 1).level == 0)
        #expect(LAAOrbMoment.input(state: .listening, level: 2).level == 1)
        #expect(LAAOrbMoment.input(state: .speaking, level: .nan).level == 0)
        #expect(paths(makeField(.input(state: .speaking, level: 1))) != paths(thinking))
    }

    @Test func seedAndSizesPreserveTheParticleField() throws {
        let moment = LAAOrbMoment.still(state: .thinking)
        let small = makeField(moment, size: 32, seed: 42)
        let large = makeField(moment, size: 64, seed: 42)
        #expect(paths(small) == paths(makeField(moment, size: 32, seed: 42)))
        #expect(paths(small) != paths(makeField(moment, size: 32, seed: 43)))
        #expect(small.litCount == large.litCount)
        #expect(large.radius == 2 * small.radius)
        let smallBounds = try #require(paths(small).first { !$0.isEmpty }?.boundingRect)
        let largeBounds = try #require(paths(large).first { !$0.isEmpty }?.boundingRect)
        #expect(abs(largeBounds.width - 2 * smallBounds.width) < 0.001)
        #expect(abs(largeBounds.height - 2 * smallBounds.height) < 0.001)
        #expect(makeField(moment, size: 120).litCount == 1704)
        var fullTurn = moment
        fullTurn.wave = 2 * .pi
        #expect(paths(small) == paths(makeField(fullTurn, size: 32, seed: 42)))
    }

    @Test func visibilityAndReduceMotionChooseNoTimeline() {
        func playback(visible: Bool = true, active: Bool = true, background: Bool = false,
                      reduceMotion: Bool = false, lowPower: Bool = false, size: CGFloat = 120) -> LAAOrbPlayback {
            .resolve(size: size, visible: visible, active: active, background: background,
                     reduceMotion: reduceMotion, lowPower: lowPower)
        }
        #expect(playback(visible: false) == .hidden)
        #expect(playback(active: false, reduceMotion: true) == .hidden)
        #expect(playback(background: true) == .hidden)
        #expect(playback(size: 0) == .hidden)
        #expect(playback(reduceMotion: true) == .still)
        #expect(playback(lowPower: true, size: 32) == .still)
        #expect(playback(lowPower: true) == .animated(interval: 1.0 / 20))
        #expect(playback(size: 32) == .animated(interval: 1.0 / 20))
        #expect(playback() == .animated(interval: 1.0 / 30))
    }

    @Test @MainActor func reduceMotionFrameIsStaticEvenAsLiveVoiceLevelChanges() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let clock = LAAOrbClock()
        let first = clock.advance(to: now, input: .input(state: .listening, level: 0))
        let next = clock.advance(to: now.addingTimeInterval(1.0 / 30), input: .input(state: .listening, level: 1))
        #expect(next.level > 0 && next.level < 1)
        #expect(next.wave > first.wave)
        let still = LAAOrbMoment.still(state: .listening)
        #expect(still.level == 0)
        #expect(paths(makeField(still)) == paths(makeField(.still(state: .listening))))
        #expect(paths(makeField(still)) != paths(makeField(next)))
    }

    @Test(arguments: [34.0, 120.0], [1.0, 2.0])
    @MainActor func renderedParticleOrbHasABrightCoreAndTransparentCorners(diameter: Double, scale: Double) throws {
        let size = CGFloat(diameter)
        let side = size * 1.3
        let palette = LAAPalette(dark: true)
        let renderer = ImageRenderer(content: Canvas { context, canvas in
            LAAOrbParticleField.frame(canvas: canvas, size: size, displayScale: scale,
                                      moment: .still(state: .thinking), paper: false, seed: 0)
                .draw(&context, palette: palette, bloom: true)
        }.frame(width: side, height: side))
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        let pixels = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                           bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
        let corner = 4 * (height * width - 1)
        let nearEdge = 4 * (height / 2 * width + width / 2 + Int(size * 0.48 * 1.1 * renderer.scale))
        let brightCore = (-1...1).flatMap { y in
            (-1...1).map { x in
                let pixel = 4 * ((height / 2 + y) * width + width / 2 + x)
                return Int(bytes[pixel]) + Int(bytes[pixel + 1]) + Int(bytes[pixel + 2])
            }
        }.max() ?? 0
        #expect(brightCore > 450)
        #expect(bytes[3] == 0 && bytes[corner + 3] == 0)
        #expect(bytes[nearEdge + 3] < 64)
    }

    private func makeField(_ moment: LAAOrbMoment, size: CGFloat = 32, seed: UInt64 = 0) -> LAAOrbParticleField {
        let side = size * 1.3
        return .frame(canvas: CGSize(width: side, height: side), size: size, displayScale: 2,
                      moment: moment, paper: false, seed: seed)
    }

    private func paths(_ field: LAAOrbParticleField) -> [Path] { field.groups.flatMap(\.paths) }
}
