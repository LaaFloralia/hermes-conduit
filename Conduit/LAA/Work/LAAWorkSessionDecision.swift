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
            if let snapshot {
                ForEach(snapshot.requests) { request in
                    // One heading per request; the card itself needs no title.
                    Text(verbatim: request.kind == "question" ? "Question" : request.name)
                        .laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    if let pending = pendingSubmission(request.id) {
                        Text(verbatim: "前の回答の結果は未確認です。同じ要求IDで再照合できます。")
                            .foregroundStyle(LAAColor.attention)
                        Button { Task { await perform(pending) } } label: { Text(verbatim: "Check Again") }
                            .laaGlassButton()
                            .accessibilityIdentifier("work.session.decision.recheck")
                    }
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
                            // The Studio input treatment (wash fill, rule, card
                            // radius), not `.roundedBorder`, whose system fill is
                            // pure white/black and hides the placeholder in dark.
                            TextField("", text: answer(request.id, index),
                                      prompt: Text(verbatim: "選択肢以外で答える").foregroundStyle(LAAColor.secondaryText),
                                      axis: .vertical)
                                .accessibilityIdentifier("work.session.decision.note.\(index)")
                                .padding(.vertical, LAASpacing.x2)
                                .studioInputField()
                            Text(verbatim: "選ばずに書くと、その内容で答えます。")
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                        actions(request, primary: "Send", decision: "answer", identifier: "work.session.decision.send",
                                ready: request.questions.indices.allSatisfy { !(answers["\(request.id):\($0)"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    } else {
                        Text(verbatim: request.detail).textSelection(.enabled).font(.system(.caption, design: .monospaced))
                        if request.kind == "tool" {
                            actions(request, primary: "Allow", decision: "allow", identifier: "work.session.decision.allow", ready: true)
                        } else {
                            actions(request, primary: nil, decision: "", identifier: "", ready: false)
                        }
                    }
                    Divider()
                }
            } else { LAALoadingDots() }
            if let failure { Text(verbatim: failure).foregroundStyle(LAAColor.attention) }
            Button { Task { await load() } } label: {
                Label { Text(verbatim: "Refresh") } icon: { Image(systemName: "arrow.clockwise") }
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.link)
                    .frame(minHeight: LAASpacing.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("work.session.decision.refresh")
        }
        .disabled(sending)
        .workCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.session.decision")
        .task(id: sessionID) { await load() }
    }

    /// One accent primary (Send or Allow) and Deny beside it as a secondary
    /// button; they stack when the text is too large to sit side by side.
    @ViewBuilder private func actions(_ request: LAAWorkDecision.Request, primary: String?, decision: String,
                                      identifier: String, ready: Bool) -> some View {
        let blocked = pendingSubmission(request.id) != nil
        let send = primary.map { title in
            Button { reply(request, decision: decision) } label: {
                Text(verbatim: title).fontWeight(.semibold)
            }
            .laaGlassButton(prominent: true)
            .disabled(blocked || !ready)
            .accessibilityIdentifier(identifier)
        }
        let deny = Button(role: .destructive) { reply(request, decision: "deny") } label: {
            // Ink on glass, not the system red: colour is for states only.
            Text(verbatim: "Deny").foregroundStyle(LAAColor.text)
        }
            .laaGlassButton()
            .disabled(blocked)
            .accessibilityIdentifier("work.session.decision.deny")
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LAASpacing.x3) { send; deny; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: LAASpacing.x2) { send; deny }
        }
    }
    private func answer(_ id: String, _ index: Int) -> Binding<String> {
        Binding(get: { answers["\(id):\(index)"] ?? "" }, set: { answers["\(id):\(index)"] = $0 })
    }
    private func pendingSubmission(_ requestID: String) -> ComposerDraftStore.Submission? {
        guard let device = bridge.deviceID else { return nil }
        return LAAWorkDrafts.pending(drafts, key: LAAWorkDrafts.key(deviceID: device, target: "decision:\(sessionID):\(requestID)"))
    }
    @MainActor private func load() async {
        do {
            let fresh: LAAWorkDecision = try await bridge.read("/v1/sessions/\(sessionID)/decision")
            snapshot = fresh; failure = nil
            if let device = bridge.deviceID {
                let prefix = "\(device):decision:\(sessionID):"
                for item in drafts.submissions where item.key.sessionID.hasPrefix(prefix) {
                    let requestID = String(item.key.sessionID.dropFirst(prefix.count))
                    if !fresh.requests.contains(where: { $0.id == requestID }) { _ = drafts.finishSubmission(item.id, restoring: false) }
                }
            }
        }
        catch { snapshot = nil; failure = "確認内容を読み取れませんでした。更新して再確認してください。" }
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
        Task { await perform(submission) }
    }
    @MainActor private func perform(_ submission: ComposerDraftStore.Submission) async {
        guard !sending, LAAWorkDrafts.canRepeat(submission) else { failure = LAAWorkDrafts.expiredMessage; return }
        sending = true

        defer { sending = false }
        do {
            guard let (body, token) = LAAWorkDrafts.request(submission) else {
                failure = "保存した回答を読み取れません。"; return
            }
            let _: LAAWorkSession = try await LAAWorkHTTP.write(bridge, path: "/v1/sessions/\(sessionID)/reply", body: body, key: token)
            _ = drafts.finishSubmission(submission.id, restoring: false)
            await load()
            onReply()
        } catch let error as LAABridgeHTTPError {
            if LAAWorkHTTP.outcomeUnknown(error) { drafts.markSubmissionUnknown(submission.id) }
            else { _ = drafts.finishSubmission(submission.id, restoring: false) }
            await load()
            failure = LAAWorkHTTP.message(error)
        } catch {
            drafts.markSubmissionUnknown(submission.id)
            failure = "回答の結果は未確認です。再送せず、Refresh で確認内容を読み直してください。"
        }
    }
}
#endif
