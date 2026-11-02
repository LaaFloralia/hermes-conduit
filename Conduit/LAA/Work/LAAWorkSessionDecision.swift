#if LAA_BUILD
import SwiftUI

struct LAAWorkDecision: Codable {
    struct Request: Codable, Identifiable {
        struct Question: Codable { let question: String; let options: [String] }
        let id: String; let kind: String; let name: String; let detail: String; let questions: [Question]
    }
    let requests: [Request]
    let requestHash: String
    let expiresAt: Double
}
struct LAAWorkSessionDecision: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let sessionID: String
    @ObservedObject var drafts: ComposerDraftStore
    let onReply: () -> Void
    @State private var snapshot: LAAWorkDecision?
    @State private var answers: [String: String] = [:]
    @State private var failure: String?
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Text(verbatim: "確認と回答").fontWeight(.semibold)
            if let snapshot {
                ForEach(snapshot.requests) { request in
                    Text(verbatim: request.name).fontWeight(.semibold)
                    if request.kind == "question" && !request.questions.isEmpty {
                        ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                            Text(verbatim: question.question)
                            ForEach(question.options, id: \.self) { option in
                                Button {
                                    answers["\(request.id):\(index)"] = option
                                } label: {
                                    Label { Text(verbatim: option) } icon: {
                                        Image(systemName: answers["\(request.id):\(index)"] == option ? "largecircle.fill.circle" : "circle")
                                    }.frame(minHeight: LAASpacing.minimumTouchTarget)
                                }
                            }
                            TextField("", text: answer(request.id, index), prompt: Text(verbatim: "回答を入力"), axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button { reply(request, decision: "answer") } label: { Text(verbatim: "回答を送信") }
                            .disabled(!request.questions.indices.allSatisfy { !(answers["\(request.id):\($0)"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    } else {
                        Text(verbatim: request.detail).textSelection(.enabled).font(.system(.caption, design: .monospaced))
                        if request.kind == "tool" {
                            Button { reply(request, decision: "allow") } label: { Text(verbatim: "この操作を許可") }
                        }
                    }
                    Button(role: .destructive) { reply(request, decision: "deny") } label: { Text(verbatim: "拒否") }
                    Divider()
                }
            } else { ProgressView() }
            if let failure { Text(verbatim: failure).foregroundStyle(LAAColor.attention) }
            Button { Task { await load() } } label: { Text(verbatim: "確認内容を更新") }
        }
        .disabled(sending)
        .workCard()
        .task(id: sessionID) { await load() }
    }
    private func answer(_ id: String, _ index: Int) -> Binding<String> {
        Binding(get: { answers["\(id):\(index)"] ?? "" }, set: { answers["\(id):\(index)"] = $0 })
    }
    @MainActor private func load() async {
        do { snapshot = try await bridge.read("/v1/sessions/\(sessionID)/decision"); failure = nil }
        catch { snapshot = nil; failure = "確認内容を取得できません。更新して再確認してください。" }
    }
    private func reply(_ request: LAAWorkDecision.Request, decision: String) {
        guard let snapshot, let device = bridge.deviceID else { return }
        struct Payload: Encodable { let requestId: String; let requestHash: String; let expiresAt: Double; let decision: String; let answers: [String: String] }
        let values = Dictionary(uniqueKeysWithValues: request.questions.indices.map { (String($0), answers["\(request.id):\($0)"] ?? "") })
        let payload = Payload(requestId: request.id, requestHash: snapshot.requestHash, expiresAt: snapshot.expiresAt, decision: decision, answers: values)
        let key = LAAWorkDrafts.key(deviceID: device, target: "decision:\(sessionID):\(request.id)")
        guard LAAWorkDrafts.pending(drafts, key: key) == nil else {
            failure = "前の回答の結果が未確認です。内容を更新して、消化されたか確認してください。"; return
        }
        guard let data = try? JSONEncoder().encode(payload), let submission = LAAWorkDrafts.reserve(drafts, key: key, text: decision, body: data, idempotency: LAABridgeIdempotencyKey()) else {
            failure = "回答を端末へ保存できません。"; return
        }
        sending = true
        Task { @MainActor in
            defer { sending = false }
            do {
                guard let (body, token) = LAAWorkDrafts.request(submission) else {
                    failure = "保存した回答を読み取れません。"; return
                }
                let _: LAAWorkSession = try await LAAWorkHTTP.write(bridge, path: "/v1/sessions/\(sessionID)/reply", body: body, key: token)
                _ = drafts.finishSubmission(submission.id, restoring: false)
                self.snapshot = nil
                onReply()
            } catch let error as LAABridgeHTTPError {
                if LAAWorkHTTP.outcomeUnknown(error) { drafts.markSubmissionUnknown(submission.id) }
                else { _ = drafts.finishSubmission(submission.id, restoring: false) }
                failure = LAAWorkHTTP.message(error)
                await load()
            } catch {
                drafts.markSubmissionUnknown(submission.id)
                failure = "回答の結果は未確認です。再送せず、確認内容を更新してください。"
            }
        }
    }
}
#endif
