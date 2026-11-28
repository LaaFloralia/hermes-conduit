#if LAA_BUILD
import Foundation

/// The engines an employee call can run on, as the Mac names them
/// (the Bridge's `GET /v1/calls/engine`).
enum LAAStaffCallEngineName: String, Codable, CaseIterable {
    /// Gemini Live over WebSocket. The key stays on the Hermes host, which
    /// mints a single-use token per connection (GeminiLiveTokenClient).
    case geminiLive = "gemini_live"
    /// The host's speech server hears and speaks; the turn runs in the
    /// employee's own Hermes chat. No external voice model.
    case localLive = "local_live"

    var engine: VoiceCallEngine {
        switch self {
        case .geminiLive: return .geminiLive
        case .localLive: return .localLive
        }
    }
}

/// The Mac's choice of engine for employee calls. The app holds no choice of
/// its own: switching engines is a change on the Mac, not an app release.
struct LAAStaffCallEngineConfig: Codable, Equatable {
    struct Switch: Codable, Equatable {
        var enabled: Bool
        /// Why it is off (`waiting_for_contract`, `key_reference_missing`,
        /// `switched_off`); nil while it is on.
        var code: String?
        var reason: String?
        var reasonJa: String?

        init(enabled: Bool, code: String? = nil, reason: String? = nil, reasonJa: String? = nil) {
            self.enabled = enabled
            self.code = code
            self.reason = reason
            self.reasonJa = reasonJa
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Anything but a clear `true` reads as off.
            enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            code = (try? container.decodeIfPresent(String.self, forKey: .code)) ?? nil
            reason = (try? container.decodeIfPresent(String.self, forKey: .reason)) ?? nil
            reasonJa = (try? container.decodeIfPresent(String.self, forKey: .reasonJa)) ?? nil
        }
    }

    /// The engines in the order a call tries them.
    var order: [LAAStaffCallEngineName]
    var engines: [String: Switch]

    init(order: [LAAStaffCallEngineName], engines: [String: Switch]) {
        self.order = order
        self.engines = engines
    }

    /// A name this build does not know drops only itself; a missing or
    /// malformed switch reads as off.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let names = (try? container.decodeIfPresent([String].self, forKey: .order)) ?? nil
        order = (names ?? []).compactMap(LAAStaffCallEngineName.init(rawValue:))
        engines = ((try? container.decodeIfPresent([String: Switch].self, forKey: .engines)) ?? nil) ?? [:]
    }

    /// Before the Mac has answered once: Local Live, which needs nothing
    /// outside the Mac; Gemini Live waits for the contract and the key.
    static let fallback = LAAStaffCallEngineConfig(
        order: [.geminiLive, .localLive],
        engines: [
            LAAStaffCallEngineName.localLive.rawValue: Switch(enabled: true),
            LAAStaffCallEngineName.geminiLive.rawValue: Switch(
                enabled: false, code: "waiting_for_contract",
                reason: "waiting for the Google AI Ultra contract / Gemini API key",
                reasonJa: "Google AI Ultraの契約とGemini APIキーを待っています"),
        ])

    func isEnabled(_ name: LAAStaffCallEngineName) -> Bool { engines[name.rawValue]?.enabled == true }

    /// The engines switched on, in the order a call tries them.
    var candidates: [VoiceCallEngine] { order.filter(isEnabled).map(\.engine) }

    /// Why an engine is off, in the owner's words; nil while it is on.
    func offReason(_ name: LAAStaffCallEngineName) -> String? {
        guard let state = engines[name.rawValue], !state.enabled else { return nil }
        return state.reasonJa ?? state.reason
    }
}

/// Reads the Mac's choice and keeps the last answer, so a call started
/// offline from the Bridge still knows the engine.
@MainActor
final class LAAStaffCallEngineStore {
    static let shared = LAAStaffCallEngineStore()
    static let path = "/v1/calls/engine"
    static let defaultsKey = "laa.staffCall.engineConfig"
    /// How long a call's start waits for the Mac before it goes on with the
    /// last answer: the call must not hang on a Bridge that is away.
    static let refreshWait: Duration = .seconds(2)

    private(set) var config: LAAStaffCallEngineConfig
    private let defaults: UserDefaults
    /// One read from the Bridge. Replaced in tests.
    var read: @MainActor () async throws -> LAAStaffCallEngineConfig
    /// Off in tests and fixtures, whose answers must not outlive them.
    var persists = true

    init(defaults: UserDefaults = .standard, read: (@MainActor () async throws -> LAAStaffCallEngineConfig)? = nil) {
        self.defaults = defaults
        self.read = read ?? {
            // A unit test never asks the real Bridge: it sets `read`.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { throw CancellationError() }
            return try await LAABridgeSession().read(LAAStaffCallEngineStore.path)
        }
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(LAAStaffCallEngineConfig.self, from: data), !saved.order.isEmpty {
            config = saved
        } else {
            config = .fallback
        }
    }

    /// The engine a plan made without asking the Mac uses (a widget launch,
    /// the voice picker): the first one switched on in the last answer.
    var engine: VoiceCallEngine { config.candidates.first ?? .localLive }

    /// Asks the Mac now. A failure, an older Bridge (404), a timeout or an
    /// answer naming no engine keeps the last one.
    @discardableResult
    func refresh() async -> LAAStaffCallEngineConfig {
        let read = self.read
        let reading = Task { @MainActor in try? await read() }
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: Self.refreshWait)
            reading.cancel()
        }
        let fresh = await reading.value
        timeout.cancel()
        if let fresh, !fresh.order.isEmpty { adopt(fresh) }
        return config
    }

    func adopt(_ fresh: LAAStaffCallEngineConfig) {
        guard fresh != config else { return }
        config = fresh
        if persists, let data = try? JSONEncoder().encode(fresh) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

@MainActor
extension AppState {
    /// The engine this employee's call runs on now. The Mac's order is read
    /// just before the call (the last answer when the Bridge is away), then
    /// the first engine in it that can connect is taken. Gemini Live is
    /// asked for its status on the Hermes host, so a switch turned on before
    /// the key exists still lands on Local Live; so does a call placed
    /// before the owner allowed Gemini Live to hear it (the next call asks,
    /// LAAEmployeeVoiceControl). Local Live is not asked first: its own
    /// start reports why when the speech server is down. Nil when no engine
    /// that is switched on can connect.
    func laaStaffCallEngine(profile: String) async -> VoiceCallEngine? {
        let config = await LAAStaffCallEngineStore.shared.refresh()
        for engine in config.candidates {
            switch engine {
            case .geminiLive:
                guard LiveVoiceProviderConsent.isGranted(.geminiLive) else { continue }
                let host = geminiLiveTokenClient.captured(profile: profile)
                if let status = try? await host.availability(), status.isAvailable { return .geminiLive }
            case .localLive:
                return .localLive
            case .qwenLive, .gptLive, .grokLive:
                continue
            }
        }
        return nil
    }
}
#endif
