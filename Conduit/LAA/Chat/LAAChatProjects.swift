#if LAA_BUILD
import Foundation
import Observation

struct LAAChatProject: Identifiable, Codable, Equatable, Sendable {
    struct Model: RawRepresentable, Codable, Equatable, Hashable, Sendable {
        let rawValue: String
        static let hydrogen = Self(rawValue: "gemini-4-hydrogen")
        static let deepSeek = Self(rawValue: "deepseek-v4.1-flash")
        static let choices: [Self] = [.hydrogen, .deepSeek]
        var name: String {
            switch self {
            case .hydrogen: "Gemini 4 Hydrogen"
            case .deepSeek: "DeepSeek V4.1 Flash"
            default: rawValue
            }
        }
        var provider: String? {
            switch self {
            case .hydrogen: "laa-agy"
            case .deepSeek: "laa-dsh"
            default: nil
            }
        }
        var effort: String { self == .deepSeek ? "high" : "low" }
    }

    struct Message: Identifiable, Codable, Equatable, Sendable {
        enum Role: String, Codable, Sendable { case user, assistant }
        let id: UUID
        let role: Role
        let text: String

        init(id: UUID = UUID(), role: Role, text: String) {
            self.id = id
            self.role = role
            self.text = text
        }
    }

    enum Kind: String, Codable, Sendable { case general, pokemon }
    let id: UUID
    var name: String
    var context: String
    let model: Model
    let kind: Kind
    var history: [Message]
    /// Reserved before any network submission; a relaunch can distinguish it
    /// from a completed question and must not silently send it again.
    var pending: Message?

    init(id: UUID = UUID(), name: String, context: String, model: Model, kind: Kind = .general,
         history: [Message] = [], pending: Message? = nil) {
        self.id = id
        self.name = name
        self.context = context
        self.model = model
        self.kind = kind
        self.history = history
        self.pending = pending
    }

    private enum CodingKeys: String, CodingKey { case id, name, context, model, kind, history, pending }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  context: try c.decodeIfPresent(String.self, forKey: .context) ?? "",
                  model: try c.decode(Model.self, forKey: .model),
                  kind: try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .general,
                  history: try c.decodeIfPresent([Message].self, forKey: .history) ?? [],
                  pending: try c.decodeIfPresent(Message.self, forKey: .pending))
    }
}

@MainActor @Observable
final class LAAChatProjectStore {
    private struct Archive: Codable {
        let schema: Int?
        let projects: [LAAChatProject]
    }
    enum Failure: Error { case unreadable, missingProject, emptyName, unsupportedModel, pendingConflict }
    static let pokemonID = UUID(uuidString: "0198828b-238f-7294-a0a6-5b65830e1602")!
    static let seeds = [
        LAAChatProject(id: UUID(uuidString: "0198828b-238f-7294-a0a6-5b65830e1601")!,
                       name: LAACopy.ChatProjects.everyday, context: "", model: .hydrogen),
        LAAChatProject(id: pokemonID, name: LAACopy.ChatProjects.pokemon, context: LAACopy.ChatProjects.pokemonContext,
                       model: .deepSeek, kind: .pokemon)
    ]
    static let shared = LAAChatProjectStore(fileURL: URL.applicationSupportDirectory
        .appending(path: "LAA/ChatProjects.json"))

    private(set) var projects: [LAAChatProject] = []
    private(set) var unavailable = false
    private(set) var inFlight: Set<UUID> = []
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        do {
            if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
                guard (archive.schema ?? 1) == 1 else { throw Failure.unreadable }
                projects = archive.projects
            } else {
                try commit(Self.seeds)
            }
        } catch {
            // Never overwrite malformed or future-version data with seed data.
            unavailable = true
        }
    }

    func project(_ id: UUID) -> LAAChatProject? { projects.first { $0.id == id } }

    @discardableResult func create(name: String, context: String, model: LAAChatProject.Model) throws -> UUID {
        guard model.provider != nil else { throw Failure.unsupportedModel }
        let project = LAAChatProject(name: try Self.validName(name), context: context, model: model)
        try commit(projects + [project])
        return project.id
    }

    func edit(_ id: UUID, name: String, context: String) throws {
        let name = try Self.validName(name)
        try change(id) { $0.name = name; $0.context = context }
    }

    func delete(_ id: UUID) throws {
        guard !inFlight.contains(id) else { throw Failure.pendingConflict }
        try commit(projects.filter { $0.id != id })
    }

    func reserve(_ question: LAAChatProject.Message, in id: UUID) throws {
        try change(id) {
            guard $0.pending == nil else { throw Failure.pendingConflict }
            $0.pending = question
        }
    }

    func release(_ id: UUID) throws { try change(id) { $0.pending = nil } }
    func startTurn(in id: UUID) { inFlight.insert(id) }
    func endTurn(in id: UUID) { inFlight.remove(id) }

    func complete(_ question: LAAChatProject.Message, answer: String, in id: UUID, localOnly: Bool = false) throws {
        try change(id) {
            guard !$0.history.contains(where: { $0.id == question.id }) else { return }
            guard localOnly ? $0.pending == nil : $0.pending?.id == question.id else { throw Failure.pendingConflict }
            $0.history += [question, .init(role: .assistant, text: answer)]
            $0.pending = nil
        }
    }

    private static func validName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.emptyName }
        return name
    }

    private func change(_ id: UUID, _ apply: (inout LAAChatProject) throws -> Void) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw Failure.missingProject }
        var next = projects
        try apply(&next[index])
        try commit(next)
    }

    private func commit(_ next: [LAAChatProject]) throws {
        guard !unavailable else { throw Failure.unreadable }
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Archive(schema: 1, projects: next))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        projects = next
    }
}
#endif
