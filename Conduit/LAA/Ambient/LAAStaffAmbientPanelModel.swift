#if LAA_BUILD
import Foundation

/// One row of the Bridge's `GET /v1/routines`, as the Mac's staff panel
/// reads it. `ownerRole`/`receiverRole` are read when the Bridge sends them
/// (lowercased role ids such as `cio`); today only `destination` names an
/// employee (`Sherlockのチャット`), and only for chat-delivered routines.
struct LAAStaffRoutineRow: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    var schedule: String? = nil
    var nextRunAt: String? = nil
    var lastRunAt: String? = nil
    var state: String? = nil
    var destination: String? = nil
    var ownerRole: String? = nil
    var receiverRole: String? = nil
    var ref: String? = nil
}

/// What the Mac's right panel shows for the selected employee (HO-26): the
/// mascot, the role, the model the open chat runs on, the last activity and
/// the employee's routines. Nothing else: no new information types (HO-11).
struct LAAStaffAmbientPanelModel: Equatable {
    enum Routines: Equatable {
        case loading
        case unavailable
        case loaded([Routine])
    }

    struct Routine: Equatable, Identifiable {
        let id: String
        let title: String
        /// When it runs next, or its schedule when the Bridge has no time.
        let detail: String
        let mark: Mark
    }

    /// The design's state marks: ● running or scheduled, ▲ needs a look,
    /// ○ paused or unknown. Never color alone.
    enum Mark: String, Equatable {
        case normal = "●", attention = "▲", unknown = "○"
    }

    let profile: String
    let name: String
    let role: String
    let model: String?
    let lastActivity: String?
    let routines: Routines

    /// The role id routines are filed under; the Monet variants share Monet's.
    static func roleKey(_ staff: LAAStaff) -> String {
        switch staff {
        case .monet, .monetUncensored: return "monet"
        default: return staff.rawValue
        }
    }

    static func belongs(_ row: LAAStaffRoutineRow, to staff: LAAStaff) -> Bool {
        let key = roleKey(staff)
        let roles = [row.ownerRole, row.receiverRole].compactMap { $0?.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if !roles.isEmpty { return roles.contains(key) }
        let name = key == "monet" ? LAAStaff.monet.name : staff.name
        return row.destination == "\(name)のチャット"
    }

    static func mark(_ state: String?) -> Mark {
        switch state {
        case "running", "scheduled": return .normal
        case "error": return .attention
        default: return .unknown
        }
    }

    /// Nil for a profile that is not an LAA employee (the panel stays away).
    static func make(profile: String, routines: [LAAStaffRoutineRow]?, failed: Bool = false,
                     model: String?, lastActivity: Date?, now: Date = Date()) -> LAAStaffAmbientPanelModel? {
        guard let staff = LAAStaff(profile: profile) else { return nil }
        let list: Routines
        if let routines {
            let mine = routines.filter { belongs($0, to: staff) }
                .sorted { (LAAWorkRoutineTime.date($0.nextRunAt) ?? .distantFuture) < (LAAWorkRoutineTime.date($1.nextRunAt) ?? .distantFuture) }
            list = .loaded(mine.map { row in
                let detail = LAAWorkRoutineTime.date(row.nextRunAt) != nil
                    ? "次回 " + LAAWorkRoutineTime.next(row.nextRunAt, now: now)
                    : (row.schedule ?? "")
                return Routine(id: row.id, title: row.name, detail: detail, mark: mark(row.state))
            })
        } else {
            list = failed ? .unavailable : .loading
        }
        let shownModel = model.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        return LAAStaffAmbientPanelModel(
            profile: profile, name: staff.name, role: staff.role,
            model: shownModel.map(LAAWorkSessionStyle.displayModel),
            lastActivity: lastActivity.map { LAADateText.relative($0, now: now) },
            routines: list)
    }
}
#endif
