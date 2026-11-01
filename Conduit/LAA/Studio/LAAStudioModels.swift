#if LAA_BUILD
import Foundation

struct LAAStudioSnapshot: Codable {
    let online: Bool
    let accepting: Bool
    let lastSeen: String?
    let projects: [LAAStudioProject]
    let principles: [LAAStudioPrinciple]
    let requests: [LAAStudioRecord]
    var contract: Int? = nil
    var supportsV2: Bool { (contract ?? 1) >= 2 }
}

struct LAAStudioProject: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let revision: Int
    let pages: [LAAStudioPage]
    let assets: [LAAStudioAsset]?
    let syncedAt: String?
    let driveUrl: String?
    let deliveredRevision: Int?
    var kind: String {
        guard let kinds = assets?.map(\.kind), !kinds.isEmpty else { return pages.isEmpty ? "Work" : "Pages" }
        return Set(kinds).count == 1 ? kinds[0].capitalized : "Mixed"
    }
}
struct LAAStudioPage: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let preview: String?
}
struct LAAStudioAsset: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String
    let url: String?
    let poster: String?
    let unavailable: String?
    let previewOnly: Bool?
    var preparing: Bool? = nil
    var usdz: String? = nil
}
struct LAAStudioPrinciple: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let version: String
    let revision: Int
    let status: String
}
struct LAAStudioRequest: Codable, Equatable {
    struct Creation: Codable, Equatable { let title: String }
    struct Principle: Codable, Equatable { let id: String; let version: String; let revision: Int }
    let id: String
    let projectId: String
    let expectedRevision: Int
    let prompt: String
    let create: Creation?
    let principle: Principle?
}
struct LAAStudioRecord: Codable, Identifiable {
    let request: LAAStudioRequest
    let status: String
    let bootId: String?
    let updatedAt: String
    let report: LAAStudioReport?
    var id: String { request.id }
    var active: Bool { ["queued", "unreceived", "accepted", "running", "approval"].contains(status) }
    var canStop: Bool { ["queued", "accepted", "running", "approval"].contains(status) }
    var canRequestAgain: Bool { ["completed", "failed", "stopped", "interrupted"].contains(status) }
}

enum LAAStudioPresentation {
    static func status(_ value: String) -> String {
        switch value {
        case "queued": LAACopy.Studio.queued
        case "unreceived": LAACopy.Studio.notReceived
        case "accepted": LAACopy.Studio.accepted
        case "running": LAACopy.Studio.running
        case "approval": LAACopy.Studio.needsApproval
        case "completed": LAACopy.Studio.completed
        case "failed": LAACopy.Studio.failed
        case "stopped": LAACopy.Studio.stopped
        case "interrupted": LAACopy.Studio.interrupted
        default: LAACopy.Studio.unknownStatus
        }
    }
    static func title(for record: LAAStudioRecord, project: LAAStudioProject?) -> String {
        project?.title ?? record.request.create?.title ?? LAACopy.Studio.work
    }
    static func hasDeliverables(_ project: LAAStudioProject) -> Bool {
        LAAStudioMedia.driveURL(project.driveUrl) != nil || project.deliveredRevision != nil ||
            project.pages.contains { LAAStudioMedia.bridgePath($0.preview) != nil } ||
            (project.assets?.contains { LAAStudioMedia.bridgePath($0.url) != nil } ?? false)
    }
}
struct LAAStudioReport: Codable {
    let id: String
    let bootId: String
    let sequence: Int
    let status: String
    let text: String
    let revision: Int?
    let approvals: [LAAStudioApproval]
    let computerCalls: Int?
}
struct LAAStudioApproval: Codable, Identifiable {
    struct Field: Codable, Identifiable {
        let name: String
        let title: String
        let type: String
        let required: Bool
        let options: [String]?
        var id: String { name }
    }
    let id: String
    let message: String
    let supported: Bool
    let allowSession: Bool
    let fields: [Field]
}

enum LAAStudioScalar: Codable, Equatable {
    case string(String), number(Double), integer(Int), boolean(Bool)
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if let value = try? box.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? box.decode(Int.self) { self = .integer(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else { self = .string(try box.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .string(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .integer(let value): try box.encode(value)
        case .boolean(let value): try box.encode(value)
        }
    }
}
struct LAAStudioAction: Codable, Equatable {
    let action: String
    let id: String
    var approvalId: String? = nil
    var accept: Bool? = nil
    var content: [String: LAAStudioScalar]? = nil
    var persist: Bool? = nil
}

enum LAAStudioAnswers {
    static func content(fields: [LAAStudioApproval.Field], raw: [String: String]) -> [String: LAAStudioScalar]? {
        var result: [String: LAAStudioScalar] = [:]
        for field in fields {
            guard let value = raw[field.name], !value.isEmpty else {
                if field.required { return nil }
                continue
            }
            if let options = field.options, !options.contains(value) { return nil }
            switch field.type {
            case "string": guard value.utf16.count <= 4000 else { return nil }; result[field.name] = .string(value)
            case "number": guard let number = Double(value), number.isFinite else { return nil }; result[field.name] = .number(number)
            case "integer": guard let number = Int(value) else { return nil }; result[field.name] = .integer(number)
            case "boolean":
                guard value == "true" || value == "false" else { return nil }
                result[field.name] = .boolean(value == "true")
            default: return nil
            }
        }
        return result
    }
}

enum LAAStudioMedia {
    private static let suffix = #"[A-Za-z0-9-]{1,100}/[a-f0-9]{64}\.(jpg|png|webp|mp4|mp3|glb|pdf|usdz)"#
    static func bridgePath(_ original: String?) -> String? {
        guard let original, matches(original, prefix: "/api/studio/media/") else { return nil }
        return "/v1" + original.dropFirst(4)
    }
    static func bridgePath(_ original: String?, allowed: Set<String>) -> String? {
        guard let path = bridgePath(original), let suffix = path.split(separator: ".").last,
              allowed.contains(String(suffix)) else { return nil }
        return path
    }
    static func bridgePathIsValid(_ path: String) -> Bool { matches(path, prefix: "/v1/studio/media/") }
    private static func matches(_ path: String, prefix: String) -> Bool {
        guard path.hasPrefix(prefix) else { return false }
        return String(path.dropFirst(prefix.count)).range(of: "^" + suffix + "$", options: .regularExpression) != nil
    }
    static func driveURL(_ value: String?) -> URL? {
        guard let value, value.range(of: #"^https://drive\.google\.com/(drive/folders|file/d)/[\w-]{10,200}(/view)?$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: value)
    }
}
#endif
