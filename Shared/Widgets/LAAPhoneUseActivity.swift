#if LAA_BUILD && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import AppIntents
import Foundation

/// An agent asking to operate the iPhone while it is in use (`laa-phone
/// unlock` found it open). The LAA Bridge starts this activity with a
/// push-to-start push (`bridge/src/phone-use/`); the owner answers Allow or
/// Don't Allow in the Dynamic Island, and while the agent works it stays as
/// "operating" with Stop, until `laa-phone lock` or its guard ends it.
///
/// The JSON keys are the Bridge's `attributes` and `content-state` keys.
struct LAAPhoneUseAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// A `LAAPhoneUsePhase` raw value; unknown values read as ended.
        var phase: String
        /// When the owner allowed it, in seconds since 1970.
        var since: Double?
        var endedAt: Double?

        var usePhase: LAAPhoneUsePhase { LAAPhoneUsePhase(rawValue: phase) ?? .ended }
    }

    var requestID: String
    /// Who asks (the Work session's name) and what for, as the agent said.
    var who: String
    var purpose: String
    /// The answer is due by then, in seconds since 1970.
    var answerBy: Double

    var answerDate: Date { Date(timeIntervalSince1970: answerBy) }
}

enum LAAPhoneUsePhase: String, Codable, CaseIterable {
    case ask, operating, ended, denied, stopped, expired

    var isFinished: Bool { self != .ask && self != .operating }
}

enum LAAPhoneUseAnswer: String, AppEnum {
    case allow, deny, stop

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Answer"
    static let caseDisplayRepresentations: [LAAPhoneUseAnswer: DisplayRepresentation] = [
        .allow: "Allow", .deny: "Don't Allow", .stop: "Stop",
    ]
}

/// The Live Activity's buttons. A LiveActivityIntent runs in the app's
/// process (launched in the background if needed), which holds the Bridge
/// pairing: the app sets `LAAPhoneUseAnswers.handler` at launch.
struct LAAPhoneUseAnswerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "iPhone Use"
    static let isDiscoverable = false

    @Parameter(title: "Request") var requestID: String
    @Parameter(title: "Answer") var answer: LAAPhoneUseAnswer

    init() {}

    init(requestID: String, answer: LAAPhoneUseAnswer) {
        self.requestID = requestID
        self.answer = answer
    }

    func perform() async throws -> some IntentResult {
        await LAAPhoneUseAnswers.send(requestID: requestID, answer: answer)
        return .result()
    }
}

enum LAAPhoneUseAnswers {
    @MainActor static var handler: ((String, LAAPhoneUseAnswer) async -> Void)?

    @MainActor static func send(requestID: String, answer: LAAPhoneUseAnswer) async {
        await handler?(requestID, answer)
    }
}
#endif
