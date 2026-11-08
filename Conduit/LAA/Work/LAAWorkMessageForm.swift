#if LAA_BUILD
import SwiftUI
import PhotosUI

struct LAAWorkMessageForm: View {
    enum Mode { case followUp, resume }
    private struct Payload: Codable { let message: String; let requestId: String?; var images: [LAAWorkImagePayload]? = nil }

    @EnvironmentObject private var bridge: LAABridgeSession
    @ObservedObject var drafts: ComposerDraftStore
    let sessionID: String
    let mode: Mode
    let canStart: Bool
    /// The model · Fast pills, from the session's controls: the follow-up row
    /// keeps them beside the picture, Send and the stop button.
    let settingsRow: AnyView?
    let interrupt: AnyView?
    let actionNotice: String?
    let onSuccess: (LAAWorkSession) -> Void
    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var photo: PhotosPickerItem?
    @State private var revision: UInt64 = 0
    @State private var sending = false
    @State private var showResolution = false
    @State private var error: String?

    init(sessionID: String, mode: Mode, drafts: ComposerDraftStore, canStart: Bool,
         settingsRow: AnyView? = nil, interrupt: AnyView? = nil, actionNotice: String? = nil,
         onSuccess: @escaping (LAAWorkSession) -> Void) {
        self.sessionID = sessionID
        self.mode = mode
        self.drafts = drafts
        self.canStart = canStart
        self.settingsRow = settingsRow
        self.interrupt = interrupt
        self.actionNotice = actionNotice
        self.onSuccess = onSuccess
    }

    private var draftKey: ComposerDraftKey? {
        bridge.deviceID.map { LAAWorkDrafts.key(deviceID: $0, target: "\(mode == .resume ? "resume" : "message"):\(sessionID)") }
    }
    private var pending: ComposerDraftStore.Submission? {
        draftKey.flatMap { LAAWorkDrafts.pending(drafts, key: $0) }
    }
    private var path: String { "/v1/sessions/\(sessionID)/\(mode == .resume ? "resume" : "messages")" }
    private var promptPlaceholder: String { mode == .resume ? "続きの指示" : "追加の指示" }
    private var composerPrefix: String { mode == .resume ? "work.resume.composer" : "work.composer" }
    private var canSubmit: Bool {
        canStart && !sending && pending == nil && !drafts.persistenceFailed
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canAttach: Bool { !sending && pending == nil && attachments.count < 4 }

    /// The follow-up row, in the order the owner reads it: the picture, the
    /// model and Fast, then the stop and Send at the trailing edge. Everything
    /// is 36pt on the same glass; only the model name gives way when narrow.
    private var actionRow: some View {
        HStack(spacing: LAASpacing.x2) {
            photoButton
            if let settingsRow { settingsRow }
            Spacer(minLength: LAASpacing.x2)
            if let interrupt { interrupt }
            sendButton
        }
    }

    private var photoButton: some View {
        PhotosPicker(selection: $photo, matching: .images) {
            Image(systemName: "photo")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(canAttach ? LAAColor.text : LAAColor.secondaryText)
                .frame(width: 36, height: 36)
                .conduitGlassControl(cornerRadius: 18, interactive: canAttach)
        }
        .disabled(!canAttach)
        .accessibilityLabel(Text(verbatim: "画像を添付"))
        .accessibilityIdentifier("work.composer.photo")
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(canSubmit ? LAAColor.link : LAAColor.secondaryText)
                .frame(width: 36, height: 36)
                .conduitGlassControl(cornerRadius: 18, tint: canSubmit ? LAAColor.link.opacity(0.12) : .clear,
                                     interactive: canSubmit)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .accessibilityLabel(Text(verbatim: LAACopy.WorkTab.send))
        .accessibilityIdentifier("\(composerPrefix).send")
    }

    /// Attached pictures stay above the field as small removable chips.
    private var chips: some View {
        HStack(spacing: LAASpacing.x2) {
            ForEach(attachments) { attachment in
                Button {
                    attachments.removeAll { $0.id == attachment.id }
                    saveDraft(text)
                } label: {
                    HStack(spacing: LAASpacing.x1) {
                        Text(verbatim: attachment.name).lineLimit(1)
                        Image(systemName: "xmark.circle")
                    }
                    .laaTextStyle(.secondary)
                    .foregroundStyle(LAAColor.secondaryText)
                    .padding(.horizontal, LAASpacing.x2)
                    .frame(minHeight: 28)
                    .background(LAAColor.subtleSurface, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: attachment.name + "を外す"))
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("work.composer.attachments")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            if mode == .resume {
                Text(verbatim: "会話履歴は引き継がれません。続きを進めるための情報を入力してください。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            if let pending {
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    Label(LAAWorkPresentation.japanese("送信結果は未確認"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention)
                    Text(verbatim: "状態を確認したうえで、同じ内容とIDで再照合できます。新しい送信は始めません。")
                    Text(verbatim: pending.draft.text).laaTextStyle(.secondary).lineLimit(4)
                    if mode == .resume {
                        Button(LAACopy.WorkTab.checkSuccessor) { Task { await reconcile(pending) } }.disabled(sending)
                    } else {
                        Button(LAACopy.WorkTab.resolveSend) { showResolution = true }.disabled(sending)
                    }
                }.workCard()
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LAAColor.attention) }
            if !canStart && mode == .followUp {
                Text(verbatim: "判断待ち・停止中は追加送信できません。状態を確認してください。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            if mode == .followUp && !attachments.isEmpty { chips }
            LAAWorkComposer(text: $text, revision: $revision, placeholder: promptPlaceholder,
                            enabled: !sending && pending == nil && !drafts.persistenceFailed, canSend: canStart,
                            onChange: saveDraft, onSubmit: submit,
                            accessibilityPrefix: mode == .resume ? "work.resume.composer" : "work.composer",
                            onImage: mode == .followUp ? addImage : nil,
                            compact: mode == .followUp)
            if mode == .followUp { actionRow }
            if let actionNotice {
                Text(verbatim: actionNotice).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if drafts.persistenceFailed {
                Text(verbatim: "下書きを保存できません。送信せず、端末の保存状態を確認してください。")
                    .foregroundStyle(LAAColor.attention).laaTextStyle(.secondary)
            }
        }
        .task(id: bridge.revision) {
            guard let key = draftKey else { return }
            revision &+= 1
            text = drafts.draft(for: key).text
            attachments = drafts.draft(for: key).attachments
        }
        .onChange(of: photo) { _, selected in
            Task { @MainActor in
                if let data = try? await selected?.loadTransferable(type: Data.self), let image = UIImage(data: data) { addImage(image) }
                photo = nil
            }
        }
        .confirmationDialog(LAAWorkPresentation.japanese("送信状況を確認しましたか？"), isPresented: $showResolution, titleVisibility: .visible) {
            if let pending, mode == .followUp {
                Button(LAACopy.WorkTab.confirmSent) { resolve(pending, restoring: false) }
                Button(LAACopy.WorkTab.restoreDraft) { resolve(pending, restoring: true) }
            }
            Button(LAACopy.WorkTab.hold, role: .cancel) { }
        } message: {
            Text(verbatim: "ログや回答を確認してください。未送信と確認できた場合だけ下書きに戻せます。判断できない場合は保留してください。")
        }
    }

    private func addImage(_ image: UIImage) {
        guard attachments.count < 4 else { error = "画像は4枚までです。"; return }
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = resized.jpegData(compressionQuality: 0.7), data.count <= 900_000 else { error = "画像を小さくして再追加してください。"; return }
        attachments.append(Attachment(id: UUID().uuidString, name: "画像\(attachments.count + 1)", uri: "data:image/jpeg;base64," + data.base64EncodedString(), mimeType: "image/jpeg", kind: .image))
        saveDraft(text)
    }

    private func resolve(_ item: ComposerDraftStore.Submission, restoring: Bool) {
        guard !sending, pending?.id == item.id else { return }
        guard drafts.finishSubmission(item.id, restoring: restoring) else {
            error = "確認結果を端末に保存できませんでした。"; return
        }
        if restoring, let draftKey {
            revision &+= 1
            text = drafts.draft(for: draftKey).text
            attachments = drafts.draft(for: draftKey).attachments
        }
        error = nil
    }

    private func saveDraft(_ value: String) {
        guard let key = draftKey else { return }
        if !drafts.save(ComposerDraft(text: value, attachments: attachments), for: key) {
            error = "下書きを端末に保存できませんでした。"
        }
    }

    private func submit() {
        guard let key = draftKey, pending == nil, canStart else { return }
        let message = text
        let images = attachments.compactMap { attachment -> LAAWorkImagePayload? in
            guard let value = attachment.uri.components(separatedBy: ",").last else { return nil }
            return LAAWorkImagePayload(data: value, mimeType: attachment.mimeType ?? "image/jpeg")
        }
        let payload = Payload(message: message, requestId: mode == .resume ? UUID().uuidString.lowercased() : nil, images: images.isEmpty ? nil : images)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(payload),
              let item = LAAWorkDrafts.reserve(drafts, key: key, text: message, body: data,
                                               idempotency: LAABridgeIdempotencyKey(), attachments: attachments) else {
            error = "送信前に下書きと要求IDを保存できませんでした。"; return
        }
        revision &+= 1
        text = ""
        attachments = []
        Task { await perform(item) }
    }

    @MainActor private func perform(_ item: ComposerDraftStore.Submission) async {
        guard LAAWorkDrafts.canRepeat(item) else { error = LAAWorkDrafts.expiredMessage; return }
        guard let (body, key) = LAAWorkDrafts.request(item) else { error = "送信記録を読み取れません。"; return }
        sending = true
        defer { sending = false }
        do {
            let result: LAAWorkSession = try await LAAWorkHTTP.write(bridge, path: path, body: body, key: key)
            guard drafts.finishSubmission(item.id, restoring: false) else {
                error = "送信結果を端末に保存できません。再送せず状態を確認してください。"; return
            }
            error = nil
            onSuccess(result)
        } catch let failure as LAABridgeHTTPError {
            if LAAWorkHTTP.outcomeUnknown(failure) { drafts.markSubmissionUnknown(item.id) }
            else if drafts.finishSubmission(item.id, restoring: true), let draftKey {
                revision &+= 1; text = drafts.draft(for: draftKey).text
            attachments = drafts.draft(for: draftKey).attachments
            }
            error = LAAWorkHTTP.message(failure)
        } catch let failure as LAABridgeError {
            drafts.markSubmissionUnknown(item.id)
            error = failure.japaneseText
        } catch {
            drafts.markSubmissionUnknown(item.id)
            self.error = "送信結果を確認できませんでした。"
        }
    }

    @MainActor private func reconcile(_ item: ComposerDraftStore.Submission) async {
        guard mode == .resume, let (body, _) = LAAWorkDrafts.request(item),
              let payload = try? JSONDecoder().decode(Payload.self, from: body), let requestID = payload.requestId else {
            error = "再開要求の記録を読み取れません。"; return
        }
        sending = true; defer { sending = false }
        do {
            let path = LAAWorkPresentation.path("/v1/sessions", query: [URLQueryItem(name: "requestId", value: requestID)])
            let page: LAAWorkPage<LAAWorkSession> = try await bridge.read(path)
            guard page.items.count == 1, page.items[0].requestId == requestID,
                  page.items[0].resumedFrom == sessionID else {
                error = "後継セッションをまだ確認できません。同じIDの記録を保持しています。"; return
            }
            guard drafts.finishSubmission(item.id, restoring: false) else {
                error = "再開結果を端末に保存できません。"; return
            }
            error = nil; onSuccess(page.items[0])
        } catch let failure as LAABridgeError { error = failure.japaneseText }
        catch { self.error = "後継セッションを確認できませんでした。" }
    }
}
#endif
