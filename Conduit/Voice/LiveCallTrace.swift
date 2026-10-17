//
//  LiveCallTrace.swift
//  Conduit
//
//  The last Grok Live call's tool steps: the session setup, which functions
//  xAI took, each function call by name and how it was answered, and tool
//  markup cut from a spoken reply. Gateway Diagnostics shows it under the
//  connection timeline and copies it with it.
//
//  Event kinds and function names only: never what the user or the model
//  said, a call's arguments, or a tool's answer.
//

import Foundation
import OSLog

private let liveCallTraceLogger = Logger(subsystem: "com.milim.relay", category: "LiveCallTrace")

@MainActor
final class LiveCallTrace {
    static let shared = LiveCallTrace()
    static let maximumSteps = 80

    private(set) var name: String?
    private var startedAt = Date()
    private(set) var steps: [String] = []
    private var droppedSteps = 0

    /// A call starts: a new trace.
    func begin(_ name: String, at date: Date = Date()) {
        self.name = name
        startedAt = date
        steps = []
        droppedSteps = 0
        note("Starting call", at: date)
    }

    func note(_ label: String, at date: Date = Date()) {
        guard name != nil else { return }
        guard steps.count < Self.maximumSteps else {
            droppedSteps += 1
            return
        }
        steps.append("+\(String(format: "%.1f", max(0, date.timeIntervalSince(startedAt))))s \(label)")
        liveCallTraceLogger.notice("Live call trace: \(label, privacy: .public)")
    }

    /// The copyable report, nil before any call.
    var report: String? {
        guard let name else { return nil }
        var lines = ["Last \(name) call: tool steps"] + steps
        if droppedSteps > 0 { lines.append("… \(droppedSteps) more steps not kept") }
        return lines.joined(separator: "\n")
    }
}
