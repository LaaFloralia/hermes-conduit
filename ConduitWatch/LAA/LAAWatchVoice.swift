#if LAA_BUILD
import SwiftUI
import AVFoundation
import Combine

/// The recorder owns its tap and serializes the converted PCM before it is sent.
private final class LAAWatchRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var pcm = Data()
    private var peakValue: Float = 0
    private var levelValue: Float = 0
    var level: Float { lock.lock(); defer { lock.unlock() }; return levelValue }
    private var converter: AVAudioConverter?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(LAAWatchAsk.sampleRate), channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { throw CocoaError(.fileWriteUnknown) }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / source.sampleRate)) + 16
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let samples = output.int16ChannelData?[0] else { return }
            self.lock.lock()
            let count = min(Int(output.frameLength), max(0, (LAAWatchAsk.maxAudioBytes - self.pcm.count) / 2))
            if count > 0 {
                self.pcm.append(Data(bytes: samples, count: count * 2))
                let maxSample = (0..<count).reduce(Int32(0)) { max($0, abs(Int32(samples[$1]))) }
                self.levelValue = Float(maxSample) / 32768
                self.peakValue = max(self.peakValue, self.levelValue)
            }
            self.lock.unlock()
        }
        try engine.start()
    }

    func finish() -> (Data, Float) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock(); defer { lock.unlock() }
        return (pcm, peakValue)
    }
}

@MainActor
final class LAAWatchVoice: ObservableObject {
    static let shared = LAAWatchVoice()
    @Published var showing = false
    @Published var staff = LAAStaff.allCases[0]
    @Published var recording = false
    @Published var elapsed = 0
    @Published var level: Float = 0
    @Published var state: LAAWatchAsk.State?
    @Published var textEntry = false
    @Published var typed = ""
    @Published var recent: [String: LAAWatchAsk.State] = [:]
    private var recorder: LAAWatchRecorder?
    private var timer: Timer?
    private var pollTimer: Timer?
    private var requestID: String?
    private var pendingURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("laa-watch-pending")
    }
    private func savePending(_ id: String) {
        try? id.write(to: pendingURL, atomically: true, encoding: .utf8)
    }
    private func readPending() -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: pendingURL.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 600,
              let id = try? String(contentsOf: pendingURL, encoding: .utf8),
              UUID(uuidString: id) != nil else { clearPending(); return nil }
        return id
    }
    private func clearPending() { try? FileManager.default.removeItem(at: pendingURL) }
    private var deadline: Date?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-laaWatchFixture"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let fixture = ProcessInfo.processInfo.arguments[index + 1]
            if fixture == "recording" { showing = true; recording = true; elapsed = 7; level = 0.2 }
            if fixture == "reply" {
                showing = true
                state = .init(requestID: "fixture", phase: .answered, transcript: "今日の予定は？", reply: "今日の予定を確認しました。")
            }
        }
        #endif
        WatchLink.shared.$askState.compactMap { $0 }.sink { [weak self] in self?.accept($0) }.store(in: &cancellables)
        WatchLink.shared.$askSignal.compactMap { $0 }.sink { [weak self] id in
            guard let self, id == (self.requestID ?? self.readPending()) else { return }
            if self.requestID == nil { self.resumePending() } else { self.poll() }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .laaWatchTransferFailed).sink { [weak self] note in
            guard let self, note.object as? String == self.requestID else { return }
            self.fail(LAAWatchCopy.notConnected)
        }.store(in: &cancellables)
    }
    func openDefault() { open(LAAStaff.allCases[0], autoRoute: true) }
    func open(_ employee: LAAStaff, autoRoute: Bool = false, textOnly: Bool = false) {
        guard !WatchVoiceCall.shared.isActive else { return }
        cancel()
        staff = employee
        self.autoRoute = autoRoute
        state = nil; elapsed = 0; typed = ""; textEntry = false; showing = true
        if textOnly { textEntry = true } else { Task { await start() } }
    }
    func showTextEntry() {
        if recording {
            timer?.invalidate(); timer = nil
            _ = recorder?.finish(); recorder = nil; recording = false
        }
        textEntry = true
    }
    private var autoRoute = false
    private var profile: String? { autoRoute ? nil : "laa-\(staff.rawValue)" }

    func start() async {
        guard !WatchVoiceCall.shared.isActive else { fail("通話中は録音できません"); return }
        guard await WatchAudio.requestPermission() else { fail("マイクの使用が許可されていません"); return }
        guard showing else { return }
        do {
            let recorder = LAAWatchRecorder()
            try recorder.start()
            self.recorder = recorder; recording = true; elapsed = 0; level = 0; state = nil
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.recording else { return }
                    self.elapsed += 1
                    self.level = self.recorder?.level ?? 0
                    if self.elapsed >= LAAWatchAsk.maxSeconds { self.done() }
                }
            }
        } catch { fail("録音を開始できません") }
    }
    func cancel() {
        timer?.invalidate(); timer = nil
        if recording { _ = recorder?.finish() }
        recorder = nil; recording = false
    }
    func done() {
        guard recording, let recorder else { return }
        timer?.invalidate(); timer = nil; recording = false; self.recorder = nil
        let (data, peak) = recorder.finish()
        guard !data.isEmpty, peak > 0.001 else { fail("音声がありません"); return }
        let id = UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("laa-voice-\(id).pcm")
        do { try data.write(to: url, options: .atomic) } catch { fail("録音を保存できません"); return }
        guard WatchLink.shared.transferAsk(url, request: .init(requestID: id, profile: profile)) else {
            try? FileManager.default.removeItem(at: url); fail(LAAWatchCopy.notConnected); return
        }
        begin(id, phase: .transcribing)
    }
    func sendText() {
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= LAAWatchAsk.maxTextLength else { return }
        if recording { timer?.invalidate(); _ = recorder?.finish(); recorder = nil; recording = false }
        let id = UUID().uuidString
        begin(id, phase: .sending)
        WatchLink.shared.send(.laaAskText(requestID: id, profile: profile, text: typed), reply: { [weak self] in
            if case .laaAskState(let state) = $0 { self?.accept(state) }
        }, failure: { [weak self] _ in self?.fail(LAAWatchCopy.notConnected) })
        textEntry = false
    }
    private func begin(_ id: String, phase: LAAWatchAsk.Phase) {
        requestID = id; deadline = Date().addingTimeInterval(90)
        savePending(id)
        state = .init(requestID: id, phase: phase)
        startPolling()
    }
    func resumePending() {
        guard let id = readPending() else { return }
        requestID = id
        deadline = Date().addingTimeInterval(90)
        state = .init(requestID: id, phase: .sending)
        startPolling()
        poll()
    }
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }
    private func poll() {
        guard let id = requestID else { return }
        guard let deadline, Date() < deadline else { fail(LAAWatchCopy.stillWorking); return }
        WatchLink.shared.send(.laaAskStatus(requestID: id), reply: { [weak self] message in
            if case .laaAskState(let state) = message, state.phase != .unknown { self?.accept(state) }
        })
    }
    private func accept(_ incoming: LAAWatchAsk.State) {
        guard incoming.requestID == requestID else { return }
        if incoming.phase == .answered && (incoming.reply?.isEmpty ?? true) { return }
        if incoming.phase == .failed && (incoming.failure?.isEmpty ?? true) { return }
        state = incoming
        if incoming.phase.isFinal {
            pollTimer?.invalidate(); pollTimer = nil
            clearPending()
            requestID = nil
            if incoming.phase == .answered { recent[incoming.profile ?? "laa-\(staff.rawValue)"] = incoming }
        }
    }
    private func fail(_ reason: String) {
        pollTimer?.invalidate(); pollTimer = nil
        state = .init(requestID: requestID ?? UUID().uuidString, phase: .failed, failure: reason)
    }
}
#endif
