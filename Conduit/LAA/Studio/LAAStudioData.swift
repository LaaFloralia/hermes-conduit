#if LAA_BUILD
import Foundation

extension LAACopy {
    enum Studio {
        static let works = "作品"
        static let requests = "依頼"
        static let requestDetail = "依頼"
        static let newRequest = "制作を依頼"
        static let newWork = "新規"
        static let work = "作品"
        static let existingWork = "既存の作品"
        static let title = "題名"
        static let prompt = "依頼"
        static let principle = "原則"
        static let none = "なし"
        static let choose = "選ぶ"
        static let yes = "はい"
        static let no = "いいえ"
        static let send = "依頼する"
        static let retry = "再試行"
        static let refresh = "更新"
        static let check = "状態を確認"
        static let stop = "停止"
        static let cancel = "キャンセル"
        static let allow = "許可"
        static let deny = "許可しない"
        static let persist = "この依頼で許可"
        static let askAgain = "直しを頼む"
        static let active = "進行中"
        static let finished = "完了した依頼"
        static let queued = "受付済み"
        static let notReceived = "受付待ち"
        static let accepted = "受付済み"
        static let running = "制作中"
        static let needsApproval = "確認待ち"
        static let completed = "完了"
        static let failed = "失敗"
        static let stopped = "停止済み"
        static let interrupted = "中断"
        static let unknownStatus = "未確認"
        static let deliverables = "納品"
        static let assets = "素材"
        static let pages = "ページ"
        static let open = "開く"
        static let openOnMac = "Macで開く"
        static let disconnected = "Studioに接続できません"
        static let notAccepting = "Studioは制作中です"
        static let workBusy = "Studioが使用中です。少し待ってから送り直してください。"
        static let permission = "この端末にはStudioの権限がありません。Macで権限を追加してください。"
        static let draft = "下書きはこの端末に保存されています。まだ送信していません。"
        static let uncertain = "送信結果を確認できていません。同じ依頼を照合してください。"
        static let missing = "Studioに依頼が見つかりません。同じ内容で再送できます。"
        static let pendingAction = "操作の結果を確認中です。自動では再送しません。"
        static let retryAction = "状態が変わらないため、同じ内容を再試行できます。"
        static let reenterAction = "操作が実行済みの可能性があります。状態を確認してから入力し直してください。"
        static let actionInFlight = "元の操作を確認中です。少し待ってから再試行してください。"
        static let actionDisconnected = "Studioに接続できません。操作が受け付け済みの可能性があります。接続後に状態を確認してください。"
        static let stopping = "Studioは停止処理中です。状態が変わるまでお待ちください。"
        static let reenter = "入力し直す"
        static let saveFailed = "下書きを保存できません。保存できるまで送信しません。"
        static let pageUnsupported = "このページはアプリでプレビューできません。LAA Studioで開いてください。"
        static let unsupported = "この形式はアプリでプレビューできません。LAA Studioで開いてください。"
        static let approvalOnMac = "この確認はMacで操作してください。有料生成や認証情報はアプリから回答できません。"
        static let emptyWorks = "まだ作品がありません。"
        static let emptyRequests = "まだ依頼がありません。"
        static let unreceived = "Studioはまだ依頼を受け取っていません。自動では再実行しません。LAA Studioで状態を確認してください。"
        static let invalid = "必須項目と入力内容を確認してください。"
        static let tooLong = "依頼文は10,000字以内にしてください。"
    }
}

extension Notification.Name { static let laaStudioChanged = Notification.Name("laa.studio.changed") }

enum LAAStudioData {
    #if DEBUG
    static var snapshotFixture: String?
    static var fixture: String? {
        if let snapshotFixture { return snapshotFixture }
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-laa-studio-fixture"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    static var fixtureRecords: [String: LAAStudioRecord] = [:]
    #endif
    @MainActor static func available(_ bridge: LAABridgeSession) -> Bool {
        #if DEBUG
        if let fixture { return fixture != "unpaired" }
        #endif
        return bridge.status == .paired
    }
    @MainActor static func snapshot(_ bridge: LAABridgeSession) async throws -> LAAStudioSnapshot {
        #if DEBUG
        if let fixture { return try sample(fixture) }
        #endif
        let result: LAABridgeResponse<LAAStudioSnapshot> = try await bridge.request(method: "GET", path: "/v1/studio/snapshot", timeout: 15)
        return result.data
    }
    @MainActor static func requestID(_ bridge: LAABridgeSession) async throws -> String {
        #if DEBUG
        if fixture != nil { return UUID().uuidString.lowercased() }
        #endif
        struct Result: Decodable { let id: String }
        let result: LAABridgeResponse<Result> = try await bridge.request(method: "GET", path: "/v1/studio/request-id")
        guard UUID(uuidString: result.data.id) != nil else { throw LAABridgeError.invalidResponse }
        return result.data.id.lowercased()
    }
    @MainActor static func record(_ id: String, bridge: LAABridgeSession) async throws -> LAAStudioRecord {
        guard UUID(uuidString: id) != nil else { throw LAABridgeError.invalidResponse }
        #if DEBUG
        if let fixture {
            if let record = fixtureRecords[id] { return record }
            guard let record = try sample(fixture).requests.first(where: { $0.id == id }) else {
                throw LAABridgeHTTPError(status: 404, code: "studio_request_missing", message: nil, retryable: false, details: nil, requestId: nil, currentETag: nil)
            }
            return record
        }
        #endif
        let response: LAABridgeResponse<LAAStudioRecord> = try await bridge.request(method: "GET", path: "/v1/studio/requests/\(id)")
        return response.data
    }
    @MainActor static func submit(_ request: LAAStudioRequest, body: Data, key: LAABridgeIdempotencyKey, bridge: LAABridgeSession) async throws -> LAAStudioRecord {
        #if DEBUG
        if fixture != nil {
            let record = LAAStudioRecord(request: request, status: "queued", bootId: nil, updatedAt: "2026-10-31T09:00:00Z", report: nil)
            fixtureRecords[request.id] = record
            return record
        }
        #endif
        let response: LAABridgeResponse<LAAStudioRecord> = try await bridge.request(method: "POST", path: "/v1/studio/requests", jsonBody: body, idempotencyKey: key, timeout: 30)
        return response.data
    }
    @MainActor static func action(_ action: LAAStudioAction, body: Data, key: LAABridgeIdempotencyKey, bridge: LAABridgeSession) async throws -> LAAStudioRecord {
        #if DEBUG
        if fixture != nil {
            let previous = try await record(action.id, bridge: bridge)
            let changed = LAAStudioRecord(request: previous.request, status: action.action == "stop" ? "stopped" : "running", bootId: previous.bootId, updatedAt: previous.updatedAt, report: previous.report)
            fixtureRecords[action.id] = changed
            return changed
        }
        #endif
        let response: LAABridgeResponse<LAAStudioRecord> = try await bridge.request(method: "POST", path: "/v1/studio/action", jsonBody: body, idempotencyKey: key, timeout: 30)
        return response.data
    }
    static func message(_ error: Error) -> String {
        if let error = error as? LAABridgeHTTPError {
            switch error.code {
            case "studio_not_connected": return LAACopy.Studio.disconnected
            case "studio_not_accepting": return LAACopy.Studio.notAccepting
            case "studio_work_busy": return LAACopy.Studio.workBusy
            case "studio_queue_dispatching": return "Studioへ渡しています。状態が更新されてからもう一度お試しください。"
            case "studio_queue_full": return "Studioの順番待ちがいっぱいです。時間をおいてもう一度お試しください。"
            case "studio_queue_unavailable": return "Studioの順番待ちを保存できませんでした。"
            case "insufficient_scope": return LAACopy.Studio.permission
            case "studio_request_missing": return LAACopy.Studio.missing
            case "studio_revision_changed": return "作品の版が変わりました。作品一覧を更新してください。"
            case "studio_principle_changed": return "原則の版が変わりました。原則一覧を更新してください。"
            case "studio_request_id_conflict": return "依頼IDが別の内容に使われています。Macで確認してください。"
            case "studio_project_missing": return "作品が見つかりません。作品一覧を更新してください。"
            case "studio_review_target_missing": return "講評の対象が見つかりません。作品を更新してください。"
            case "studio_review_id_conflict": return "講評IDが別の内容に使われています。Macで確認してください。"
            case "studio_revision_unknown": return "作品の版を確認できません。作品を更新してください。"
            case "studio_approval_on_mac", "studio_approval_expired": return LAACopy.Studio.approvalOnMac
            case "idempotency_key_in_flight": return LAACopy.Studio.actionInFlight
            case "studio_stopping": return LAACopy.Studio.stopping
            default: return error.legacyError.japaneseText
            }
        }
        return (error as? LAABridgeError)?.japaneseText ?? LAABridgeError.invalidResponse.japaneseText
    }
    static func isAuthorizationFailure(_ error: Error) -> Bool {
        if let failure = error as? LAABridgeHTTPError { return [401, 403].contains(failure.status) }
        guard let failure = error as? LAABridgeError else { return false }
        return [.unauthorized, .revoked, .forbidden, .keychain].contains(failure)
    }
    #if DEBUG
    static func sample(_ mode: String) throws -> LAAStudioSnapshot {
        if mode == "offline" { throw LAABridgeError.networkUnreachable }
        if mode == "disconnected" || mode == "error" {
            throw LAABridgeHTTPError(status: 503, code: mode == "disconnected" ? "studio_not_connected" : "failure", message: nil, retryable: false, details: nil, requestId: nil, currentETag: nil)
        }
        let requestID = "0f6b1c2e-6f1a-4c55-9d43-0d5f6f3b8a11"
        let projectID = "70175325-5cf4-421f-8a6f-95beae8fca92"
        let questionID = "5e2c1c2e-6f1a-4c55-9d43-0d5f6f3b8a11"
        let text = mode == "long" ? String(repeating: "制作の進捗を確認しています。", count: 150) : "資料の構成を確認しています。"
        let fields = [LAAStudioApproval.Field(name: "format", title: "形式", type: "string", required: true, options: ["PDF", "Slides"]),
                      LAAStudioApproval.Field(name: "copies", title: "枚数", type: "integer", required: true, options: nil)]
        let approval = LAAStudioApproval(id: questionID, message: mode == "unsupported" ? "有料生成の確認が必要です。" : "出力形式を選んでください。", supported: mode != "unsupported", allowSession: true, fields: fields)
        let report = LAAStudioReport(id: requestID, bootId: projectID, sequence: 2, status: "approval", text: text, revision: nil, approvals: [approval], computerCalls: nil)
        let request = LAAStudioRequest(id: requestID, projectId: projectID, expectedRevision: 3, prompt: "新しい紹介資料を作ってください。", create: nil, principle: nil)
        let record = LAAStudioRecord(request: request, status: mode == "v2-completed" ? "completed" : "approval", bootId: projectID, updatedAt: "2026-10-31T09:00:00Z", report: mode == "v2-completed" ? nil : report)
        let project = LAAStudioProject(id: projectID, title: "サービス紹介資料", revision: 3,
                                       pages: [.init(id: "page1", name: "Cover", preview: nil)], assets: [], syncedAt: "2026-10-31T09:00:00Z", driveUrl: "https://drive.google.com/file/d/1234567890/view", deliveredRevision: 3)
        let principle = LAAStudioPrinciple(id: "principle1", name: "LAA", version: "6", revision: 3, status: "adopted")
        var snapshot = LAAStudioSnapshot(online: true, accepting: true, lastSeen: nil, projects: mode == "empty" ? [] : [project], principles: [principle], requests: mode == "empty" ? [] : [record])
        if mode.hasPrefix("v2") { snapshot.contract = 2 }
        return snapshot
    }
    #endif
}

struct LAAStudioDraft: Codable, Equatable {
    var requestID: String?
    var projectID: String?
    var expectedRevision: Int = 0
    var title: String = ""
    var prompt: String = ""
    var principle: LAAStudioRequest.Principle?
    var pending = false
    var submissionBody: Data?
    var submissionKey: String?
    var kind: String?
    var references: [String]?
    var workBusy: Bool?
    var isNew: Bool { projectID == nil }
    func request() -> LAAStudioRequest? {
        guard let requestID, UUID(uuidString: requestID) != nil,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, composedPrompt.utf16.count <= 10000,
              !isNew || (!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf16.count <= 300) else { return nil }
        return LAAStudioRequest(id: requestID, projectId: projectID ?? requestID, expectedRevision: isNew ? 0 : expectedRevision,
                                prompt: composedPrompt,
                                create: isNew ? .init(title: title.trimmingCharacters(in: .whitespacesAndNewlines)) : nil,
                                principle: principle)
    }
    var composedPrompt: String {
        var parts = [prompt.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let kind { parts.append("制作の種類: " + kind) }
        if let references, !references.isEmpty { parts.append("参考資料（Drive）:\n" + references.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }
    mutating func submission(rotateKey: Bool = false) throws -> (request: LAAStudioRequest, body: Data, key: LAABridgeIdempotencyKey)? {
        guard let request = request() else { return nil }
        let body: Data
        if let submissionBody {
            guard try JSONDecoder().decode(LAAStudioRequest.self, from: submissionBody) == request else { return nil }
            body = submissionBody
        } else {
            body = try JSONEncoder().encode(request)
            submissionBody = body
        }
        if rotateKey || submissionKey == nil { submissionKey = LAABridgeIdempotencyKey().value }
        guard let submissionKey, let key = LAABridgeIdempotencyKey(restoring: submissionKey) else { return nil }
        return (request, body, key)
    }
    mutating func resetSubmission() {
        pending = false; requestID = nil; submissionBody = nil; submissionKey = nil; workBusy = nil
    }
}

enum LAAStudioDraftStore {
    enum LoadResult {
        case missing, loaded(LAAStudioDraft), unreadable
    }
    static func directory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Studio", isDirectory: true)
    }
    static func file(deviceID: String, draftID: String? = nil, directory: URL = directory()) -> URL? {
        guard !deviceID.isEmpty, deviceID.count <= 100,
              deviceID.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains),
              draftID.map({ UUID(uuidString: $0) != nil }) ?? true else { return nil }
        let suffix = draftID.map { "-again-\($0.lowercased())" } ?? ""
        return directory.appendingPathComponent("draft-\(deviceID)\(suffix).json")
    }
    static func load(deviceID: String, draftID: String? = nil, directory: URL = directory()) -> LAAStudioDraft? {
        if case .loaded(let draft) = loadResult(deviceID: deviceID, draftID: draftID, directory: directory) { return draft }
        return nil
    }
    static func loadResult(deviceID: String, draftID: String? = nil, directory: URL = directory()) -> LoadResult {
        guard let url = file(deviceID: deviceID, draftID: draftID, directory: directory) else { return .unreadable }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url), let draft = try? JSONDecoder().decode(LAAStudioDraft.self, from: data) else { return .unreadable }
        return .loaded(draft)
    }
    static func save(_ draft: LAAStudioDraft, deviceID: String, draftID: String? = nil, directory: URL = directory()) -> Bool {
        guard let url = file(deviceID: deviceID, draftID: draftID, directory: directory) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(draft).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }
    static func clear(deviceID: String, draftID: String? = nil, directory: URL = directory()) -> Bool {
        guard let url = file(deviceID: deviceID, draftID: draftID, directory: directory) else { return false }
        do { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }; return true }
        catch { return false }
    }
}
#endif
