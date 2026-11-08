#if LAA_BUILD
import Foundation
import UIKit
import WatchConnectivity

enum LAAWatchAskRouting {
    // Aliases describe names, not profile IDs; the current staff list owns identities.
    static let aliases: [String: [String]] = [
        // シエル: the secretary's name before she became Monet (2026-11-08).
        "Monet": ["モネット", "モネ", "シエル", "Ciel"], "Argus": ["アーガス"],
        "Morgan": ["モーガン"], "Sherlock": ["シャーロック"], "Merlin": ["マーリン"],
        "Talos": ["タロス"], "Ada": ["エイダ"]
    ]

    static func route(_ text: String, profile: String?) -> (profile: String, text: String)? {
        let staff = LAAStaff.allCases
        guard let first = staff.first else { return nil }
        if let profile {
            guard let selected = LAAStaff(profile: profile) else { return nil }
            return ("laa-\(selected.rawValue)", text)
        }
        var matches: [(LAAStaff, String.Index)] = []
        for member in staff {
            let uncensored = member.rawValue.hasSuffix("-uncensored")
            let base = member.name.replacingOccurrences(of: "（無検閲）", with: "")
            for alias in [base] + (aliases[base] ?? []) {
                let prefix = uncensored ? alias + "無検閲" : alias
                guard text.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil else { continue }
                var rest = text.index(text.startIndex, offsetBy: prefix.count)
                if text[rest...].hasPrefix("さん") { rest = text.index(rest, offsetBy: 2) }
                guard rest < text.endIndex, "にへ、,".contains(text[rest]) else { continue }
                matches.append((member, text.index(after: rest)))
            }
        }
        let unique = Set(matches.map { $0.0.rawValue })
        guard unique.count == 1, let match = matches.first else { return ("laa-\(first.rawValue)", text) }
        return ("laa-\(match.0.rawValue)", text)
    }
}

@MainActor
final class LAAWatchAskService {
    private var states: [String: LAAWatchAsk.State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var expires: [String: Date] = [:]

    func state(_ id: String) -> LAAWatchAsk.State {
        prune()
        return states[id] ?? .init(requestID: id, phase: .unknown, profile: nil, transcript: nil, reply: nil, failure: nil)
    }

    func receiveText(id: String, profile: String?, text: String) {
        guard tasks[id] == nil, states[id] == nil else { return }
        start(id: id, profile: profile, audio: nil, text: text)
    }

    func receiveAudio(_ request: LAAWatchAsk.Request, data: Data) {
        guard tasks[request.requestID] == nil, states[request.requestID] == nil else { return }
        guard Self.validAudio(data, sampleRate: request.sampleRate) else {
            publish(.init(requestID: request.requestID, phase: .failed, profile: nil, transcript: nil, reply: nil, failure: "録音形式を確認できませんでした"))
            return
        }
        start(id: request.requestID, profile: request.profile, audio: data, text: nil)
    }

    private func start(id: String, profile: String?, audio: Data?, text: String?) {
        guard UUID(uuidString: id) != nil, profile == nil || LAAStaff(profile: profile!) != nil else {
            publish(.init(requestID: id, phase: .failed, profile: nil, transcript: nil, reply: nil, failure: "要求を確認できませんでした"))
            return
        }
        publish(.init(requestID: id, phase: .received, profile: profile, transcript: nil, reply: nil, failure: nil))
        let deadline = Date().addingTimeInterval(25)
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "laa.watch.ask") {
            Task { @MainActor [weak self] in self?.tasks[id]?.cancel() }
        }
        tasks[id] = Task { [weak self] in
            defer {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                self?.tasks[id] = nil
            }
            guard let self else { return }
            do {
                let transcript: String
                if let audio {
                    self.update(id, phase: .transcribing)
                    transcript = try await LAABridgeSession().withAuthenticatedClient { client, credentials in
                        try await client.transcribeWatchAudio(audio, credentials: credentials)
                    }
                } else { transcript = text ?? "" }
                guard !Task.isCancelled else { throw CancellationError() }
                if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.update(id, phase: .silent); return }
                guard transcript.count <= LAAWatchAsk.maxTextLength,
                      let route = LAAWatchAskRouting.route(transcript, profile: profile),
                      !route.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ShortcutSendError(message: "本文を確認できませんでした")
                }
                var next = self.state(id)
                next.phase = .sending; next.profile = route.profile; next.transcript = transcript
                self.publish(next)
                let result = try await AppStateRuntimeRegistry.shared.appState.sendFromShortcut(
                    ShortcutSendRequest(text: route.text, chatName: "Watch", profile: route.profile, waitsForAnswer: true),
                    deadline: deadline)
                next.phase = Self.phase(result)
                if case .answered(let reply) = result { next.reply = reply }
                self.publish(next)
            } catch {
                var next = self.state(id); next.phase = .failed; next.failure = Self.failure(error)
                self.publish(next)
            }
        }
    }

    static func validAudio(_ data: Data, sampleRate: Int) -> Bool {
        sampleRate == LAAWatchAsk.sampleRate && !data.isEmpty &&
            data.count <= LAAWatchAsk.maxAudioBytes && data.count.isMultiple(of: 2)
    }

    static func queuedNotification(_ value: LAAWatchAsk.State) -> LAAWatchAsk.State {
        .init(requestID: value.requestID, phase: value.phase, profile: value.profile,
              transcript: nil, reply: nil, failure: nil)
    }

    static func phase(_ outcome: ShortcutSendOutcome) -> LAAWatchAsk.Phase {
        switch outcome {
        case .answered: return .answered
        case .stillWorking: return .stillWorking
        case .needsInput: return .needsInput
        case .queued, .joinedRunningReply, .sent: return .queued
        }
    }

    static func failure(_ error: Error) -> String {
        if let http = error as? LAABridgeHTTPError {
            switch http.status {
            case 403: return "Watchの音声はまだ接続されていません"
            case 429: return "音声が混み合っています。もう一度お試しください"
            case 503: return "音声を利用できません。しばらくしてからお試しください"
            case 504: return "音声の処理が時間切れになりました"
            default: break
            }
        }
        if let bridge = error as? LAABridgeError, bridge == .forbidden { return "Watchの音声はまだ接続されていません" }
        return "処理できませんでした。接続を確認してください"
    }

    private func update(_ id: String, phase: LAAWatchAsk.Phase) {
        var next = state(id); next.phase = phase; publish(next)
    }

    private func prune() {
        let now = Date()
        for (id, expiry) in expires where !(now < expiry) {
            states[id] = nil
            expires[id] = nil
        }
    }

    private func publish(_ value: LAAWatchAsk.State) {
        prune()
        states[value.requestID] = value
        if value.phase.isFinal {
            let expiry = Date().addingTimeInterval(600)
            expires[value.requestID] = expiry
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                guard let self, self.expires[value.requestID] == expiry else { return }
                self.states[value.requestID] = nil
                self.expires[value.requestID] = nil
            }
        }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let message = WatchVoiceWire.encode(.laaAskState(value))
        let notification = WatchVoiceWire.encode(.laaAskState(Self.queuedNotification(value)))
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(notification) }
        } else { session.transferUserInfo(notification) }
    }
}
#endif
