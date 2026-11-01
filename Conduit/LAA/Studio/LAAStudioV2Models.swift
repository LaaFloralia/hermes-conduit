#if LAA_BUILD
import Foundation

// Color details may be structured values; preserve their shape for display and caching.
enum LAAStudioValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String)
    case array([LAAStudioValue]), object([String: LAAStudioValue])

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([LAAStudioValue].self) { self = .array(value) }
        else { self = .object(try box.decode([String: LAAStudioValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .null: try box.encodeNil()
        case .bool(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .string(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .object(let value): try box.encode(value)
        }
    }
    var text: String {
        switch self {
        case .null: return ""
        case .bool(let value): return String(value)
        case .number(let value): return value.rounded() == value ? String(format: "%.0f", value) : String(value)
        case .string(let value): return value
        case .array(let value): return value.map(\.text).joined(separator: ", ")
        case .object(let value): return value.keys.sorted().map { "\($0): \(value[$0]?.text ?? "")" }.joined(separator: " · ")
        }
    }
}

struct LAAStudioCatalog: Codable {
    struct Principle: Codable, Identifiable {
        struct Color: Codable, Identifiable {
            let name: String
            let value: String
            let rgb: LAAStudioValue?
            let oklch: LAAStudioValue?
            let cmykApprox: LAAStudioValue?
            var id: String { name }
        }
        struct Font: Codable, Identifiable {
            let name: String
            let family: String
            let weight: Double
            let size: Double
            var id: String { name }
        }
        struct Reference: Codable, Identifiable {
            let name: String
            let role: String
            let adoptedElements: String
            let media: String?
            let width: Double?
            let height: Double?
            var id: String { name }
        }
        struct Priority: Codable, Identifiable {
            let title: String
            let description: String
            var id: String { title }
        }
        let id: String
        let name: String
        let version: String
        let revision: Int
        let status: String
        let description: String
        let colors: [Color]
        let fonts: [Font]
        let references: [Reference]
        let templates: [String]
        let priorities: [Priority]?
        var requestPrinciple: LAAStudioRequest.Principle { .init(id: id, version: version, revision: revision) }
    }
    struct Document: Codable, Identifiable {
        let id: String
        let title: String
        let category: String
        let detail: String
        let format: String
        let media: String?
        let bytes: Int64?
        let driveUrl: String
        let unavailable: String?
    }
    struct Capability: Codable, Identifiable {
        let id: String
        let title: String
        let description: String
        let prompt: String
    }
    let etag: String
    let updatedAt: String
    let principles: [Principle]
    let adoptedPrincipleId: String?
    let documents: [Document]
    let capabilities: [Capability]
    let brief: [String]
}

struct LAAStudioProjectDetail: Codable {
    struct Version: Codable, Identifiable {
        let id: String
        let revision: Int
        let kind: String
        let name: String
        let createdAt: String
        let bytes: Int64
        let media: String?
        let poster: String?
        let width: Double?
        let height: Double?
        let duration: Double?
        let previewOnly: Bool?
        let preparing: Bool?
        let unavailable: String?
        let usdz: String?
    }
    struct Delivery: Codable {
        let driveUrl: String
        let revision: Int
    }
    let project: LAAStudioProject
    let versions: [Version]
    let delivery: Delivery?
    let reviews: [LAAStudioReview]
}

struct LAAStudioReview: Codable, Identifiable, Equatable {
    struct Target: Codable, Equatable, Hashable {
        let kind: String
        let id: String?
        static let project = Target(kind: "project", id: nil)
        static func page(_ id: String) -> Target { .init(kind: "page", id: id) }
        static func version(_ id: String) -> Target { .init(kind: "version", id: id) }
    }
    let id: String
    let projectId: String
    let revision: Int
    let target: Target
    let verdict: String?
    let comment: String?
    var createdAt: String? = nil

    static func canSubmit(verdict: String?, comment: String) -> Bool {
        (verdict == nil || ["adopt", "revise", "reject"].contains(verdict ?? "")) && comment.utf16.count <= 4000 &&
            (verdict != nil || !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    static func history(_ reviews: [LAAStudioReview], target: Target, including added: LAAStudioReview?) -> [LAAStudioReview] {
        var result = reviews.filter { $0.target == target }
        guard let added, added.target == target, !result.contains(where: { $0.id == added.id }) else { return result }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ value: String?) -> Date? { value.flatMap { fractional.date(from: $0) ?? plain.date(from: $0) } }
        guard let time = date(added.createdAt), result.allSatisfy({ date($0.createdAt) != nil }) else { return result }
        let index = result.firstIndex { date($0.createdAt).map { $0 < time } ?? false } ?? result.endIndex
        result.insert(added, at: index)
        return Array(result.prefix(200))
    }
    func sameSubmission(as other: LAAStudioReview) -> Bool {
        id == other.id && projectId == other.projectId && revision == other.revision &&
            target == other.target && verdict == other.verdict && comment == other.comment
    }
}
#endif
