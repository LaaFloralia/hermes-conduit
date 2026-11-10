#if LAA_BUILD
import ImageIO
import QuartzCore
import SwiftUI

/// A drag turns the mascot any distance around; a flick carries on and slows.
/// Left alone it comes back to face the viewer, the short way round.
struct StaffTurnSpin: Equatable {
    static let turnsPerPoint = 1.0 / 520
    static let settleAfter = 1.6

    var turn = 0.0
    var velocity = 0.0
    var dragging = false
    var sinceTouch = Double.infinity

    var isFacingFront: Bool {
        !dragging && velocity == 0 && abs(turn - turn.rounded()) < 0.002
    }

    mutating func drag(dx: Double) {
        dragging = true
        velocity = 0
        sinceTouch = 0
        turn += dx * Self.turnsPerPoint
    }

    mutating func release(velocityX: Double) {
        dragging = false
        velocity = velocityX * Self.turnsPerPoint
    }

    mutating func advance(by dt: Double) {
        guard !dragging else { return }
        sinceTouch += dt
        turn += velocity * dt
        velocity *= exp(-2.2 * dt)
        if abs(velocity) < 0.02 { velocity = 0 }
        guard sinceTouch > Self.settleAfter, velocity == 0 else { return }
        turn += (turn.rounded() - turn) * min(1, dt * 4)
    }

    func frame(of count: Int) -> Int {
        Int(((turn - turn.rounded(.down)) * Double(count)).rounded()) % count
    }
}

/// The pre-rendered turn under the finger. One frame decodes at a time off the
/// main thread, so a fast drag skips frames rather than queueing them, and only
/// the frame on screen stays in memory.
@MainActor
final class StaffMascotTurner: ObservableObject {
    @Published private(set) var frame: CGImage?
    @Published private(set) var turning = false

    private var spin = StaffTurnSpin()
    private var source: CGImageSource?
    private var sourceURL: URL?
    private var sourceCount = 1
    private var sourceGeneration = 0
    private var loading = false
    private let loadSource: @Sendable (URL) -> CGImageSource?
    private var link: CADisplayLink?
    private var last = CACurrentMediaTime()
    private var wanted = 0
    private var decoding = false
    private let decoder = DispatchQueue(label: "com.laa.staff.turn", qos: .userInteractive)

    init(loadSource: @escaping @Sendable (URL) -> CGImageSource? = {
        CGImageSourceCreateWithURL($0 as CFURL, nil)
    }) {
        self.loadSource = loadSource
    }

    func drag(by dx: Double, url: URL) {
        turning = true
        spin.drag(dx: dx)
        if sourceURL != url || (source == nil && !loading) {
            sourceGeneration &+= 1
            let generation = sourceGeneration
            sourceURL = url
            source = nil
            frame = nil
            loading = true
            decoding = false
            let loadSource = loadSource
            // Creating a HEIC source reads its container and frame metadata.
            // Keep the first drag as light as subsequent decoded frames.
            decoder.async { [weak self] in
                let source = loadSource(url)
                let count = source.map { max(CGImageSourceGetCount($0), 1) } ?? 1
                DispatchQueue.main.async {
                    guard let self, self.sourceGeneration == generation else { return }
                    self.loading = false
                    self.source = source
                    self.sourceCount = count
                    if self.turning { self.show() }
                }
            }
        }
        show()
    }

    func release(velocityX: Double, reduceMotion: Bool) {
        guard turning else { return }
        guard !reduceMotion else { return stop() }
        spin.release(velocityX: velocityX)
        guard link == nil else { return }
        last = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        spin = StaffTurnSpin()
        turning = false
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        spin.advance(by: min(now - last, 0.1))
        last = now
        show()
        if spin.isFacingFront { stop() }
    }

    private func show() {
        guard let source else { return }
        wanted = spin.frame(of: sourceCount)
        guard !decoding else { return }
        decoding = true
        let index = wanted
        let generation = sourceGeneration
        decoder.async { [weak self] in
            let image = CGImageSourceCreateImageAtIndex(source, index, [
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
            DispatchQueue.main.async {
                guard let self, self.sourceGeneration == generation else { return }
                self.decoding = false
                self.frame = image
                if self.wanted != index { self.show() }
            }
        }
    }
}

/// The mascot's looped video, with the 360° turn taking over under the finger.
struct StaffMascotView: View {
    let profile: String
    let name: String
    var fallbackURL: URL? = nil
    var size: CGFloat
    var activity: StaffAvatarActivity = .resting
    var level: Float = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var turner = StaffMascotTurner()
    @State private var lastX: CGFloat = 0

    private var turnURL: URL? { StaffAssetResolver.bundled.resolve(profile: profile).turn }
    private var showsTurn: Bool { turner.turning && turner.frame != nil }

    var body: some View {
        ZStack {
            StaffAvatarView(profile: profile, name: name, fallbackURL: fallbackURL, size: size, activity: activity)
                .opacity(showsTurn ? 0 : 1)
            if let frame = turner.frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .opacity(showsTurn ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeOut(duration: 0.14), value: showsTurn)
        .scaleEffect(x: reduceMotion ? 1 : 1 + CGFloat(level) * 0.05,
                     y: reduceMotion ? 1 : 1 - CGFloat(level) * 0.05, anchor: .bottom)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .contentShape(Rectangle())
        .gesture(turnGesture)
        .onDisappear { turner.stop() }
    }

    private var turnGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard let turnURL else { return }
                turner.drag(by: value.translation.width - lastX, url: turnURL)
                lastX = value.translation.width
            }
            .onEnded { value in
                lastX = 0
                turner.release(velocityX: value.velocity.width, reduceMotion: reduceMotion)
            }
    }
}
#endif
