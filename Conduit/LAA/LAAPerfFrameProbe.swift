#if LAA_BUILD && DEBUG && targetEnvironment(simulator)
import QuartzCore
import SwiftUI

/// Opt-in lab control. It is unavailable to both Release and device builds.
struct LAAPerfFrameProbeControl: View {
    static let launchArgument = "-LAA_PERF_FRAME_PROBE"

    @State private var recorder = Recorder()
    @State private var status = "idle"

    var body: some View {
        Button {
            if status == "recording" {
                status = recorder.stop() ? "saved" : "unavailable"
            } else {
                status = recorder.start() ? "recording" : "unavailable"
            }
        } label: {
            Text(verbatim: "Frame probe").font(.caption2)
                .padding(5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("laa.perf.frame-probe")
        .accessibilityValue(status)
        .onDisappear { recorder.cancel() }
    }

    @MainActor private final class Recorder: NSObject {
        struct Interval: Encodable {
            var end = 0.0
            var actual = 0.0
            var expected = 0.0
        }
        struct Capture: Encodable {
            let started: CFTimeInterval
            let stopped: CFTimeInterval
            let overflow: Bool
            let intervals: [Interval]
        }

        // The callback writes only numeric values to a fixed-size, uniquely
        // owned buffer. No UI update, file I/O or encoding during a scroll.
        private var buffer = Array(repeating: Interval(), count: 8192)
        private var count = 0
        private var overflow = false
        private var previous: (timestamp: CFTimeInterval, expected: CFTimeInterval)?
        private var started = 0.0
        private var link: CADisplayLink?
        private var output: URL?

        func start() -> Bool {
            let env = ProcessInfo.processInfo.environment
            guard let id = env["LAA_PERF_FRAME_TRIAL"].flatMap(UUID.init(uuidString:)),
                  let kind = env["LAA_PERF_FRAME_KIND"], ["chat", "work"].contains(kind),
                  let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return false }
            output = folder.appendingPathComponent("laa-perf-frame-\(id.uuidString)-\(kind).json")
            cancel()
            count = 0
            overflow = false
            previous = nil
            let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
            started = CACurrentMediaTime()
            link = displayLink
            displayLink.add(to: .main, forMode: .common)
            return true
        }

        @objc private func tick(_ displayLink: CADisplayLink) {
            let stamp = displayLink.timestamp
            let expected = displayLink.targetTimestamp - stamp
            defer { previous = (stamp, expected) }
            guard let previous, stamp > previous.timestamp, previous.expected > 0 else { return }
            guard count < buffer.count else { overflow = true; return }
            buffer[count] = Interval(end: stamp, actual: stamp - previous.timestamp, expected: previous.expected)
            count += 1
        }

        func stop() -> Bool {
            cancel()
            let stopped = CACurrentMediaTime()
            guard let output else { return false }
            do {
                let capture = Capture(started: started, stopped: stopped, overflow: overflow,
                                      intervals: Array(buffer.prefix(count)))
                try JSONEncoder().encode(capture).write(to: output, options: .atomic)
                return true
            } catch {
                return false
            }
        }

        func cancel() {
            link?.invalidate()
            link = nil
        }
    }
}
#endif
