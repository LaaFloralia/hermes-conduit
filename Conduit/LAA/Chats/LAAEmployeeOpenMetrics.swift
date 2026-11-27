#if LAA_BUILD
import Foundation
import os

/// How long one employee chat open took, phase by phase, on the monotonic
/// clock from the tap (D-25). Only numbers and fixed names: no message
/// text, identifiers, addresses or secrets, so it can go to the connection
/// timeline (Gateway Diagnostics) and the log as it is.
struct LAAEmployeeOpenMetrics: Equatable {
    enum Scenario: String, Equatable {
        /// The first open since launch.
        case cold
        /// The first open after returning to the app.
        case resume
        /// Any other open: another employee, or the same one again.
        case `switch`
    }

    enum NetworkClass: String, Equatable {
        case wifi, cellular, offline
    }

    /// The phases in the order an open normally reaches them. Each keeps
    /// its first time only.
    enum Phase: String, CaseIterable, Equatable {
        case cachedTranscript, composerEditable, ticket, socketOpen, catalog, sessionResume, history, modelInfo, liveReady
    }

    let scenario: Scenario
    let networkClass: NetworkClass
    let startedAt: ContinuousClock.Instant
    private(set) var phases: [Phase: Int] = [:]
    private(set) var totalMs: Int?
    private(set) var outcome: String?

    init(scenario: Scenario, networkClass: NetworkClass, startedAt: ContinuousClock.Instant = ContinuousClock.now) {
        self.scenario = scenario
        self.networkClass = networkClass
        self.startedAt = startedAt
    }

    var isFinished: Bool { totalMs != nil }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        let ms = parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
        return Int(max(0, ms))
    }

    /// The first time `phase` is reached; later ones and any after the
    /// open finished are ignored.
    mutating func mark(_ phase: Phase, at now: ContinuousClock.Instant = ContinuousClock.now) {
        guard !isFinished, phases[phase] == nil else { return }
        phases[phase] = Self.milliseconds(now - startedAt)
    }

    mutating func finish(outcome: String, at now: ContinuousClock.Instant = ContinuousClock.now) {
        guard !isFinished else { return }
        totalMs = Self.milliseconds(now - startedAt)
        self.outcome = outcome
    }

    func ms(_ phase: Phase) -> Int? { phases[phase] }
    var cachedTranscriptMs: Int? { ms(.cachedTranscript) }
    var composerEditableMs: Int? { ms(.composerEditable) }
    var ticketMs: Int? { ms(.ticket) }
    var socketOpenMs: Int? { ms(.socketOpen) }
    var catalogMs: Int? { ms(.catalog) }
    var sessionResumeMs: Int? { ms(.sessionResume) }
    var historyMs: Int? { ms(.history) }
    var modelInfoMs: Int? { ms(.modelInfo) }
    var liveReadyMs: Int? { ms(.liveReady) }

    /// One line: "Employee open cold/wifi handled total=812ms cachedTranscript=41ms …".
    var summary: String {
        let parts = Phase.allCases.compactMap { phase in phases[phase].map { "\(phase.rawValue)=\($0)ms" } }
        let total = totalMs.map { " total=\($0)ms" } ?? ""
        return "Employee open \(scenario.rawValue)/\(networkClass.rawValue) \(outcome ?? "open")\(total)"
            + (parts.isEmpty ? "" : " " + parts.joined(separator: " "))
    }

    /// The connection timeline's step labels that mark a phase.
    static func phase(forConnectionStep label: String) -> Phase? {
        guard !label.contains(" failed") else { return nil }
        if label.hasPrefix("Ticket") || label.hasPrefix("Password sign-in and ticket") { return .ticket }
        if label.hasPrefix("Socket open") { return .socketOpen }
        if label.hasPrefix("Chat list") { return .catalog }
        if label.hasPrefix("Chat history") { return .history }
        if label.hasPrefix("Chat ready") { return .sessionResume }
        return nil
    }

    /// The open last finished, for Gateway Diagnostics and lab checks.
    @MainActor static var latest: LAAEmployeeOpenMetrics?
    static let log = Logger(subsystem: "com.laa.performance", category: "EmployeeOpen")
}
#endif
