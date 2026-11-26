#if LAA_BUILD
import UIKit
import UserNotifications
import XCTest
@testable import Conduit

/// HO-08 / HO-15 / HO-06 / HO-26: which employee a notification carries,
/// the call card's state and coding, the Watch's Monet plan, and the Mac's
/// staff panel. Pure logic; the drawn cards are in LAAAmbientSnapshotTests.
@MainActor
final class LAAAmbientTests: XCTestCase {
    private func sessionID(_ link: String, _ meta: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "laa-bridge:\(link)#\(encoded)"
    }

    // MARK: Notification mascot (kind → staff → asset)

    func testBridgeKindsSpeakForMonetOrTheAskingEmployee() {
        XCTAssertEqual(LAANotificationStaffArt.staff(kind: "monet.report", profile: "laa-monet", staffHint: nil), .monet)
        XCTAssertEqual(LAANotificationStaffArt.staff(kind: "decision.new", profile: "laa-monet", staffHint: "laa-cfo"), .cfo)
        XCTAssertEqual(LAANotificationStaffArt.staff(kind: "decision.new", profile: "laa-monet", staffHint: nil), .monet)
        // An unknown asker falls back to Monet rather than to no image.
        XCTAssertEqual(LAANotificationStaffArt.staff(kind: "decision.new", profile: nil, staffHint: "laa-nobody"), .monet)
        // Only a decision takes a hint: Monet's report is always Monet's.
        XCTAssertEqual(LAANotificationStaffArt.staff(kind: "monet.report", profile: nil, staffHint: "laa-cto"), .monet)
        XCTAssertEqual(LAANotificationStaffArt.staff(kind: "session.question", profile: "laa-monet", staffHint: nil), .monet)
    }

    func testOtherPushesUseTheirProfile() {
        // A routine's report and a chat reply come from the job's profile.
        XCTAssertEqual(LAANotificationStaffArt.staff(kind: nil, profile: "laa-cio", staffHint: nil), .cio)
        XCTAssertEqual(LAANotificationStaffArt.staff(kind: "", profile: " LAA-CTO ", staffHint: nil), .cto)
        XCTAssertNil(LAANotificationStaffArt.staff(kind: nil, profile: "default", staffHint: nil))
        XCTAssertNil(LAANotificationStaffArt.staff(kind: nil, profile: nil, staffHint: nil))
        XCTAssertNil(LAANotificationStaffArt.staff(kind: nil, profile: "research", staffHint: nil))
    }

    func testAssetNames() {
        XCTAssertEqual(LAANotificationStaffArt.resourceName(.monet), "monet")
        XCTAssertEqual(LAANotificationStaffArt.resourceName(.monetUncensored), "monet-uncensored")
        let root = URL(fileURLWithPath: "/bundle")
        XCTAssertEqual(LAANotificationStaffArt.bundledImage(.cfo, root: root, exists: { _ in true })?.path, "/bundle/staff/cfo.png")
        XCTAssertNil(LAANotificationStaffArt.bundledImage(.cfo, root: root, exists: { _ in false }))
    }

    func testEveryStaffHasABundledStillInTheRepository() throws {
        // The build copies docs/laa/assets/staff/<id>/<id>-avatar-512.png.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let staffRoot = repo.appendingPathComponent("docs/laa/assets/staff")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: staffRoot.path), "repository not reachable from the simulator")
        for staff in LAAStaff.allCases {
            let name = LAANotificationStaffArt.resourceName(staff)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staffRoot.appendingPathComponent("\(name)/\(name)-avatar-512.png").path), name)
        }
    }

    func testAttachmentIsACopyAndAddedOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("laa-ambient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("staff"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor(red: 0.5, green: 0.4, blue: 0.8, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let source = folder.appendingPathComponent("staff/monet.png")
        try png.write(to: source)
        let bundle = try XCTUnwrap(Bundle(url: folder))
        let attachment = try XCTUnwrap(LAANotificationStaffArt.attachment(.monet, bundle: bundle))
        XCTAssertEqual(attachment.identifier, LAANotificationStaffArt.attachmentIdentifier)
        // The bundle's file stays where it was.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        let content = UNMutableNotificationContent()
        LAANotificationStaffArt.decorate(content, kind: "monet.report", profile: "laa-monet", staffHint: nil) { _ in attachment }
        XCTAssertEqual(content.attachments.map(\.identifier), ["laa-staff"])
        var asked = 0
        LAANotificationStaffArt.decorate(content, kind: "monet.report", profile: "laa-monet", staffHint: nil) { _ in asked += 1; return attachment }
        XCTAssertEqual(content.attachments.count, 1)
        XCTAssertEqual(asked, 0)
        XCTAssertNil(LAANotificationStaffArt.attachment(.cto, bundle: bundle), "no still for this employee in the bundle")
    }

    func testMetaReadsTheAskingStaffOnlyWhenWellFormed() {
        let link = "laa://work/decisions/dec_0123456789abcdef"
        let base: [String: Any] = ["v": 1, "k": "decision.new", "id": "dec_0123456789abcdef", "o": ["はい", "いいえ"]]
        XCTAssertEqual(LAANotificationMeta.parse(sessionID(link, base.merging(["st": "laa-cfo"]) { $1 }))?.staff, "laa-cfo")
        XCTAssertNil(LAANotificationMeta.parse(sessionID(link, base.merging(["st": "LAA CFO"]) { $1 }))?.staff)
        XCTAssertNil(LAANotificationMeta.parse(sessionID(link, base.merging(["st": 7]) { $1 }))?.staff)
        let plain = LAANotificationMeta.parse(sessionID(link, base))
        XCTAssertNil(plain?.staff)
        XCTAssertNotNil(plain?.quick, "the answer buttons are unaffected")
    }

    func testReportLedgerKeepsOnlyMonetReportTimes() throws {
        let suite = "laa.ambient.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LAAMonetReportLedger.note(kind: "decision.new", at: Date(timeIntervalSince1970: 100), defaults: defaults)
        XCTAssertNil(LAAMonetReportLedger.lastReport(defaults: defaults))
        LAAMonetReportLedger.note(kind: "monet.report", at: Date(timeIntervalSince1970: 200), defaults: defaults)
        XCTAssertEqual(LAAMonetReportLedger.lastReport(defaults: defaults), Date(timeIntervalSince1970: 200))
        let standard = try XCTUnwrap(UserDefaults(suiteName: suite + ".std"))
        defer { standard.removePersistentDomain(forName: suite + ".std") }
        standard.set(3, forKey: LAAWatchAmbientSource.decisionCountKey)
        XCTAssertEqual(LAAWatchAmbientSource.current(defaults: standard, reports: defaults),
                       LAAWatchAmbient(waiting: 3, reportAt: Date(timeIntervalSince1970: 200)))
    }

    // MARK: Live Activity state and coding

    func testCallContentStateKeysAndOldValues() throws {
        let state = LAAStaffCallAttributes.ContentState(phase: .speaking, connectedAt: Date(timeIntervalSince1970: 1000))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["phase", "connectedAt"])
        XCTAssertEqual(object["phase"] as? String, "speaking")
        XCTAssertEqual(object["connectedAt"] as? Double, 1000)
        let unknown = try JSONDecoder().decode(LAAStaffCallAttributes.ContentState.self, from: Data(#"{"phase":"ringing"}"#.utf8))
        XCTAssertEqual(unknown.callPhase, .listening)
        XCTAssertNil(unknown.connectedDate)
        let attributes = LAAStaffCallAttributes(profile: "laa-cfo", name: "Morgan", link: nil)
        let round = try JSONDecoder().decode(LAAStaffCallAttributes.self, from: JSONEncoder().encode(attributes))
        XCTAssertEqual(round, attributes)
    }

    func testTurnContentStateKeysStayTheRelays() throws {
        // HermesTurnAttributes' doc comment: the relay's content-state keys.
        let state = HermesTurnAttributes.ContentState(phase: .tool, tool: .web, tools: 2, context: 40, endedAt: Date(timeIntervalSince1970: 5))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["phase", "tool", "tools", "context", "endedAt"])
        let relay = try JSONDecoder().decode(HermesTurnAttributes.ContentState.self, from: Data(#"{"phase":"thinking","tools":0}"#.utf8))
        XCTAssertEqual(relay.turnPhase, .thinking)
    }

    func testCallSnapshotMapsToCardPhases() {
        let context = LAAEmployeeCallContext(profile: "laa-cfo", name: "Morgan", conversationID: "s1")
        func phase(_ edit: (inout LAAEmployeeCallSnapshot) -> Void) -> LAAStaffCallPhase {
            var snapshot = LAAEmployeeCallSnapshot(context: context, phase: .connected, connectedAt: Date(timeIntervalSince1970: 10))
            edit(&snapshot)
            return LAAStaffCallActivityState.phase(of: snapshot)
        }
        XCTAssertEqual(phase { _ in }, .listening)
        XCTAssertEqual(phase { $0.speaking = true }, .speaking)
        XCTAssertEqual(phase { $0.activity = .thinking }, .thinking)
        XCTAssertEqual(phase { $0.muted = true; $0.speaking = true }, .muted, "muted outranks the employee speaking")
        XCTAssertEqual(phase { $0.phase = .connecting }, .connecting)
        XCTAssertEqual(phase { $0.phase = .reconnecting }, .connecting)
        XCTAssertEqual(phase { $0.phase = .ending }, .ended)
        XCTAssertEqual(phase { $0.phase = .failed("x") }, .ended)

        let snapshot = LAAEmployeeCallSnapshot(context: context, phase: .connected, connectedAt: Date(timeIntervalSince1970: 10), speaking: true)
        let content = LAAStaffCallActivityState.content(of: snapshot, now: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(content.connectedAt, 10)
        XCTAssertNil(content.endedAt)
        let attributes = LAAStaffCallActivityState.attributes(of: context)
        XCTAssertEqual(attributes.profile, "laa-cfo")
        XCTAssertEqual(LAAWidgetStaffArt.profile(fromLink: try! XCTUnwrap(attributes.link)), "laa-cfo")
    }

    func testCallUpdatesOnlyWhenPhaseOrConnectionChanges() {
        let a = LAAStaffCallAttributes.ContentState(phase: .listening, connectedAt: Date(timeIntervalSince1970: 10))
        XCTAssertTrue(LAAStaffCallActivityState.differs(a, from: nil))
        XCTAssertFalse(LAAStaffCallActivityState.differs(a, from: a))
        XCTAssertTrue(LAAStaffCallActivityState.differs(.init(phase: .speaking, connectedAt: Date(timeIntervalSince1970: 10)), from: a))
        XCTAssertTrue(LAAStaffCallActivityState.differs(.init(phase: .listening, connectedAt: Date(timeIntervalSince1970: 11)), from: a))
        XCTAssertFalse(LAAStaffCallActivityState.differs(.init(phase: .listening, connectedAt: Date(timeIntervalSince1970: 10), endedAt: Date()), from: a))
    }

    func testWidgetStillForProfilesAndTurnLinks() {
        XCTAssertEqual(LAAWidgetStaffArt.imageName(profile: "laa-monet"), "LAAStaffAvatar-monet")
        XCTAssertEqual(LAAWidgetStaffArt.imageName(profile: "laa-monet-dots"), "LAAStaffAvatar-monet")
        XCTAssertEqual(LAAWidgetStaffArt.imageName(profile: "LAA-Soap"), "LAAStaffAvatar-soap")
        XCTAssertNil(LAAWidgetStaffArt.imageName(profile: "default"))
        XCTAssertNil(LAAWidgetStaffArt.imageName(profile: nil))
        XCTAssertNil(LAAWidgetStaffArt.imageName(profile: "laa-nobody"))
        let link = ConduitAppLink.session(id: "abc", profile: "laa-cto", dashboard: "d1").url
        XCTAssertEqual(LAAWidgetStaffArt.profile(fromLink: link), "laa-cto")
        XCTAssertNil(LAAWidgetStaffArt.profile(fromLink: ConduitAppLink.session(id: "abc").url))
        // Every name the widget asks for is in the extension's catalog.
        for id in LAAWidgetStaffArt.known {
            XCTAssertNotNil(UIImage(named: "LAAStaffAvatar-\(id)", in: Bundle(for: LAAAmbientTests.self), with: nil), id)
        }
    }

    // MARK: Watch

    func testWatchPlanPutsDecisionsFirstThenAFreshReport() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let decisions = LAAWatchAmbientPlan.make(LAAWatchAmbient(waiting: 2, reportAt: now), now: now)
        XCTAssertEqual(decisions.kind, .decisions)
        XCTAssertEqual(decisions.line, "判断待ち 2件")
        XCTAssertEqual(decisions.score, 82)
        XCTAssertEqual(LAAWatchAmbientPlan.make(LAAWatchAmbient(waiting: 40, reportAt: nil), now: now).score, 85)

        let hourAgo = now.addingTimeInterval(-3600)
        let report = LAAWatchAmbientPlan.make(LAAWatchAmbient(waiting: 0, reportAt: hourAgo), now: now)
        XCTAssertEqual(report.kind, .report)
        XCTAssertTrue(report.line.hasPrefix("報告 "))
        XCTAssertEqual(report.until, hourAgo.addingTimeInterval(LAAWatchAmbientPlan.reportWindow))
        XCTAssertTrue(report.score > 0 && report.score < 80)
        let older = LAAWatchAmbientPlan.make(LAAWatchAmbient(waiting: 0, reportAt: now.addingTimeInterval(-5 * 3600)), now: now)
        XCTAssertLessThan(older.score, report.score, "news fades")

        for ambient in [nil, LAAWatchAmbient(waiting: 0, reportAt: now.addingTimeInterval(-7 * 3600)),
                        LAAWatchAmbient(waiting: 0, reportAt: now.addingTimeInterval(60)), LAAWatchAmbient(waiting: -3, reportAt: nil)] {
            let idle = LAAWatchAmbientPlan.make(ambient, now: now)
            XCTAssertEqual(idle.kind, .idle)
            XCTAssertEqual(idle.score, 0)
            XCTAssertEqual(idle.line, "話しかける")
        }
    }

    func testWatchContextCarriesAmbientAndReadsOldContexts() throws {
        var context = WatchPhoneContext(activeDashboardID: "d")
        context.laaAmbient = LAAWatchAmbient(waiting: 1, reportAt: Date(timeIntervalSince1970: 7))
        XCTAssertEqual(WatchPhoneContext.decode(context.encoded())?.laaAmbient, context.laaAmbient)
        let old = try JSONSerialization.data(withJSONObject: ["voices": [:], "callsRing": false])
        XCTAssertNil(WatchPhoneContext.decode([WatchPhoneContext.key: old])?.laaAmbient)
        XCTAssertNotNil(WatchPhoneContext.decode([WatchPhoneContext.key: old]))
    }

    // MARK: Mac staff panel

    func testPanelFiltersRoutinesByStaff() {
        let byDestination = LAAStaffRoutineRow(id: "a", name: "A", destination: "Sherlockのチャット")
        let byRole = LAAStaffRoutineRow(id: "b", name: "B", destination: "定期実行", ownerRole: "CIO")
        let otherRole = LAAStaffRoutineRow(id: "c", name: "C", destination: "Sherlockのチャット", ownerRole: "cto")
        let monet = LAAStaffRoutineRow(id: "d", name: "D", destination: "Monetのチャット")
        let scheduled = LAAStaffRoutineRow(id: "e", name: "E", destination: "定期実行")
        XCTAssertTrue(LAAStaffAmbientPanelModel.belongs(byDestination, to: .cio))
        XCTAssertTrue(LAAStaffAmbientPanelModel.belongs(byRole, to: .cio))
        XCTAssertFalse(LAAStaffAmbientPanelModel.belongs(otherRole, to: .cio), "a role the Bridge names wins over the destination")
        XCTAssertFalse(LAAStaffAmbientPanelModel.belongs(scheduled, to: .cio))
        XCTAssertTrue(LAAStaffAmbientPanelModel.belongs(monet, to: .monet))
        XCTAssertTrue(LAAStaffAmbientPanelModel.belongs(LAAStaffRoutineRow(id: "f", name: "F", receiverRole: "monet"), to: .monetUncensored))
    }

    func testPanelModelOrdersRoutinesAndMarksState() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        let rows = [
            LAAStaffRoutineRow(id: "late", name: "週次", schedule: "毎週", nextRunAt: iso.string(from: now.addingTimeInterval(86400 * 3)), state: "scheduled", destination: "Sherlockのチャット"),
            LAAStaffRoutineRow(id: "soon", name: "朝", nextRunAt: iso.string(from: now.addingTimeInterval(600)), state: "running", destination: "Sherlockのチャット"),
            LAAStaffRoutineRow(id: "broken", name: "壊れた", schedule: "毎日 18:00", state: "error", destination: "Sherlockのチャット"),
            LAAStaffRoutineRow(id: "paused", name: "停止", state: "paused", destination: "Sherlockのチャット"),
            LAAStaffRoutineRow(id: "other", name: "他", destination: "Adaのチャット"),
        ]
        let model = try XCTUnwrap(LAAStaffAmbientPanelModel.make(profile: "laa-cio", routines: rows, model: "gpt-6.1-sol",
                                                                 lastActivity: now.addingTimeInterval(-120), now: now))
        XCTAssertEqual(model.name, "Sherlock")
        XCTAssertEqual(model.role, "CIO")
        XCTAssertEqual(model.model, "GPT 6.1 Sol")
        XCTAssertNotNil(model.lastActivity)
        guard case .loaded(let list) = model.routines else { return XCTFail("routines") }
        XCTAssertEqual(list.map(\.id), ["soon", "late", "broken", "paused"])
        XCTAssertEqual(list.map(\.mark), [.normal, .normal, .attention, .unknown])
        XCTAssertTrue(list[0].detail.hasPrefix("次回 "))
        XCTAssertEqual(list[2].detail, "毎日 18:00")

        XCTAssertEqual(LAAStaffAmbientPanelModel.make(profile: "laa-cio", routines: nil, model: nil, lastActivity: nil)?.routines, .loading)
        let failed = LAAStaffAmbientPanelModel.make(profile: "laa-cio", routines: nil, failed: true, model: "  ", lastActivity: nil)
        XCTAssertEqual(failed?.routines, .unavailable)
        XCTAssertNil(failed?.model, "an empty model reads as unknown")
        XCTAssertNil(failed?.lastActivity)
        XCTAssertNil(LAAStaffAmbientPanelModel.make(profile: "default", routines: [], model: nil, lastActivity: nil))
    }
}
#endif
