#if LAA_BUILD
import Foundation
import SwiftUI

/// An employee's words for "thinking" (hq/roles/roster.yaml `thinking`,
/// served by the Bridge's `GET /v1/staff`): one base word and its
/// alternatives. The app keeps none of its own (D-01, owner 2026-11-26), so
/// an employee added on the Mac needs no app release.
struct LAAThinkingWords: Codable, Equatable {
    let base: String
    let alt: [String]

    /// Nil unless base is a non-empty string and alt only non-empty strings
    /// (the Bridge omits a malformed entry; the app checks again).
    init?(base: String, alt: [String]) {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, alt.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        self.base = base
        self.alt = alt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = try container.decode(String.self, forKey: .base)
        let alt = try container.decodeIfPresent([String].self, forKey: .alt) ?? []
        guard let words = LAAThinkingWords(base: base, alt: alt) else {
            throw DecodingError.dataCorruptedError(forKey: .base, in: container, debugDescription: "malformed thinking")
        }
        self = words
    }
}

/// One row of `GET /v1/staff`.
struct LAAStaffMember: Codable, Equatable {
    let id: String
    let profile: String
    let name: String?
    let thinking: LAAThinkingWords?

    init(id: String, profile: String? = nil, name: String? = nil, thinking: LAAThinkingWords?) {
        self.id = id
        self.profile = profile ?? "laa-" + id
        self.name = name
        self.thinking = thinking
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self.init(id: id,
                  profile: try? container.decodeIfPresent(String.self, forKey: .profile),
                  name: try? container.decodeIfPresent(String.self, forKey: .name),
                  // A malformed `thinking` drops only itself, never the row.
                  thinking: try? container.decodeIfPresent(LAAThinkingWords.self, forKey: .thinking))
    }
}

/// The `data` of `GET /v1/staff`. A malformed row drops only itself.
struct LAAStaffList: Decodable, Equatable {
    let staff: [LAAStaffMember]

    init(staff: [LAAStaffMember]) { self.staff = staff }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decode([Lenient].self, forKey: .staff)
        staff = rows.compactMap(\.member)
    }

    private enum CodingKeys: String, CodingKey { case staff }
    private struct Lenient: Decodable {
        let member: LAAStaffMember?
        init(from decoder: Decoder) throws { member = try? LAAStaffMember(from: decoder) }
    }
}

/// The dice of one pick. Seeded (SplitMix64) for tests and the DEBUG
/// fixture, the system's otherwise.
struct LAAThinkingRandom: RandomNumberGenerator {
    private var state: UInt64?

    init(seed: UInt64? = nil) { state = seed }

    mutating func next() -> UInt64 {
        guard var z = state else {
            var system = SystemRandomNumberGenerator()
            return system.next()
        }
        z &+= 0x9E37_79B9_7F4A_7C15
        state = z
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum LAAThinkingPick {
    /// The base word about seven times in ten (D-01 decision 6).
    static let basePerMille: UInt64 = 700

    /// One word for one wait: base 70%, else one alternative at random;
    /// no alternatives, the base.
    static func pick<G: RandomNumberGenerator>(_ words: LAAThinkingWords, using random: inout G) -> String {
        guard !words.alt.isEmpty, random.next() % 1000 >= basePerMille else { return words.base }
        return words.alt[Int(random.next() % UInt64(words.alt.count))]
    }
}

/// What an employee's chat says while it waits for the reply: each wait
/// picks one word and holds it until the reply ends (D-01 decision 6). The
/// pill, the Mac's window and the turn's Live Activity read the same hold.
/// A tool running says 作業中 instead (LAAChatWorking); Work Sessions and
/// unknown profiles say Thinking.
@MainActor
final class LAAStaffThinking: ObservableObject {
    static let shared = LAAStaffThinking()
    /// No words for the profile, or none read yet.
    nonisolated static let fallback = "Thinking"
    nonisolated static let path = "/v1/staff"
    /// A turn that reads idle for less than this and runs again is the same
    /// wait (a stale snapshot just as the prompt went out).
    static let resumeGrace: TimeInterval = 3

    @Published private(set) var staff: [LAAStaffMember]
    private var byProfile: [String: LAAThinkingWords] = [:]
    /// One wait per profile: its word, and when the turn last read idle.
    private struct Hold { let word: String; var endedAt: Date? }
    private var holds: [String: Hold] = [:]
    private var random: LAAThinkingRandom
    private let file: URL?
    private let now: () -> Date
    /// A UI fixture's words are fixed: no read replaces them.
    private var pinned = false

    init(file: URL? = LAAStaffThinking.defaultFile, random: LAAThinkingRandom = .init(), now: @escaping () -> Date = Date.init) {
        self.file = file
        self.random = random
        self.now = now
        staff = []
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if file == Self.defaultFile, args.contains("-LAA_FIXTURE_STAFF_THINKING") {
            if let seed = args.firstIndex(of: "-LAA_FIXTURE_THINKING_SEED")
                .flatMap({ args.indices.contains($0 + 1) ? UInt64(args[$0 + 1]) : nil }) {
                self.random = LAAThinkingRandom(seed: seed)
            }
            adopt(LAAStaffThinkingFixture.staff)
            pinned = true
            return
        }
        #endif
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([LAAStaffMember].self, from: data) {
            adopt(saved)
        }
    }

    nonisolated static var defaultFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LAAStaff", isDirectory: true)
            .appendingPathComponent("thinking.json")
    }

    func words(forProfile profile: String) -> LAAThinkingWords? {
        byProfile[Self.key(profile)]
    }

    // MARK: Waits

    /// A wait the owner just started (a send): always a fresh pick.
    @discardableResult
    func beginWait(profile: String) -> String {
        let key = Self.key(profile)
        let word = pick(key)
        holds[key] = Hold(word: word, endedAt: nil)
        return word
    }

    /// The word of the wait running now: the held one, or a fresh pick when
    /// the last wait ended (a turn started elsewhere, or after a relaunch).
    /// Reading never resumes an ended wait: a view drawn just after the reply
    /// shows the held word without keeping the wait open.
    func word(profile: String) -> String {
        let key = Self.key(profile)
        if let hold = holds[key], hold.endedAt.map({ now().timeIntervalSince($0) < Self.resumeGrace }) ?? true {
            return hold.word
        }
        return beginWait(profile: profile)
    }

    /// The turn runs again without a send (a turn started elsewhere, or a
    /// stale idle snapshot): under the grace it is the same wait, after it
    /// a new one with a fresh pick.
    func resumeWait(profile: String) {
        let key = Self.key(profile)
        guard let ended = holds[key]?.endedAt else { return }
        if now().timeIntervalSince(ended) < Self.resumeGrace {
            holds[key]?.endedAt = nil
        } else {
            beginWait(profile: profile)
        }
    }

    /// The Live Activity's word for the wait running now; nil when it would
    /// say Thinking anyway.
    func liveActivityWord(profile: String) -> String? {
        let word = word(profile: profile)
        return word == Self.fallback ? nil : word
    }

    /// The turn read idle: the next wait picks again.
    func endWait(profile: String) {
        let key = Self.key(profile)
        guard holds[key] != nil, holds[key]?.endedAt == nil else { return }
        holds[key]?.endedAt = now()
    }

    private func pick(_ key: String) -> String {
        guard let words = byProfile[key] else { return Self.fallback }
        return LAAThinkingPick.pick(words, using: &random)
    }

    private static func key(_ profile: String) -> String {
        profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Reading

    /// One read from the Mac. A failure, an older Bridge (404) or an empty
    /// list (its roster unreadable) keeps the last good list.
    func refresh(bridge: LAABridgeSession) async {
        guard !pinned, bridge.status == .paired else { return }
        guard let list: LAAStaffList = try? await bridge.read(Self.path), !Task.isCancelled else { return }
        apply(list)
    }

    /// Adopts a read and keeps it on the device for a cold launch offline.
    func apply(_ list: LAAStaffList) {
        guard !list.staff.isEmpty, list.staff != staff else { return }
        adopt(list.staff)
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(list.staff).write(to: file, options: .atomic)
        } catch {
            // The words still apply for this launch.
        }
    }

    private func adopt(_ members: [LAAStaffMember]) {
        staff = members
        var map: [String: LAAThinkingWords] = [:]
        for member in members {
            if let thinking = member.thinking { map[Self.key(member.profile)] = thinking }
        }
        byProfile = map
    }
}

extension View {
    /// Reads the employees' words on launch, when the pairing changes and
    /// each time the app comes back.
    func laaStaffThinkingSync(_ bridge: LAABridgeSession, active: Bool) -> some View {
        task(id: "staff|\(bridge.revision)|\(active)") {
            guard active else { return }
            await LAAStaffThinking.shared.refresh(bridge: bridge)
        }
    }
}

#if DEBUG
/// `-LAA_FIXTURE_STAFF_THINKING`: the words of the owner's table
/// (D-01, 2026-11-26) for UI fixtures and screenshots, without a Bridge.
/// Debug only; the shipped app reads them from the Bridge.
enum LAAStaffThinkingFixture {
    // Copied from hq/roles/roster.yaml (the owner's table, D-01), not retyped.
    // laa-design:staff-voice begin hq/roles/roster.yaml thinking (Debug fixture)
    static let staff: [LAAStaffMember] = [
        member("monet", "Monet", "むむむ… 🐣", ["うーんと… 🐥", "ひらめけ、私 🪄", "トークンもぐもぐ 🍪"]),
        member("cto", "Ada", "かちゃかちゃ… ⚙️", ["むむ、仕組みは… 🔧", "ロジックこねこね 🧩", "ひらめき待ち 💡"]),
        member("cfo", "Morgan", "ふむ… 🧮", ["むむ、釣り合いは… ⚖️", "数字と相談中 🦉", "そろばん、ぱちぱち 🧮"]),
        member("cos", "Merlin", "さてさて… 🪄", ["段取りこねこね 🧵", "あれとこれを、くるくる 🪄", "むむ、ひと工夫 🧙"]),
        member("cio", "Sherlock", "はてさて… 🔎", ["おや、むむ… 🧐", "点と点を、じーっ 👀", "ふむ、もしや… 🕵️"]),
        member("argus", "Argus", "じーっ… 🦅", ["あわてず、じっくり 🍵", "ふむ、見定め中 👁️", "静かに思案中 🌙"]),
        member("cso", "Talos", "むう… 🛡️", ["じぃー… 👀", "ふむ、念入りに 🔐", "じっくり、どっしり 🗿"]),
        LAAStaffMember(id: "researcher", name: "Fermi", thinking: nil),
        LAAStaffMember(id: "design", name: "Iris", thinking: nil),
    ]
    // laa-design:staff-voice end

    private static func member(_ id: String, _ name: String, _ base: String, _ alt: [String]) -> LAAStaffMember {
        LAAStaffMember(id: id, name: name, thinking: LAAThinkingWords(base: base, alt: alt))
    }
}
#endif
#endif
