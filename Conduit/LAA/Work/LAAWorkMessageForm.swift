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
    /// A message to quote into the field, from the transcript's 引用.
    let quote: LAAWorkQuoteRequest?
    /// Told the text and pictures of a follow-up the Bridge accepted, so the
    /// transcript can show it until Paseo's history does.
    let onSent: ((String, [Attachment]) -> Void)?
    let onSuccess: (LAAWorkSession) -> Void
    @State private var focusRequest = 0
    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var photo: PhotosPickerItem?
    @State private var revision: UInt64 = 0
    @State private var sending = false
    @State private var showResolution = false
    @State private var error: String?
    @State private var preview: LAAWorkImagePreview.Request?

    init(sessionID: String, mode: Mode, drafts: ComposerDraftStore, canStart: Bool,
         settingsRow: AnyView? = nil, interrupt: AnyView? = nil, actionNotice: String? = nil,
         quote: LAAWorkQuoteRequest? = nil,
         onSent: ((String, [Attachment]) -> Void)? = nil,
         onSuccess: @escaping (LAAWorkSession) -> Void) {
        self.sessionID = sessionID
        self.mode = mode
        self.drafts = drafts
        self.canStart = canStart
        self.settingsRow = settingsRow
        self.interrupt = interrupt
        self.actionNotice = actionNotice
        self.quote = quote
        self.onSent = onSent
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
            // Before the spacer, so the model's name shows whenever the row
            // has room for it; only a row too narrow drops it.
            if let settingsRow { settingsRow.layoutPriority(1) }
            Spacer(minLength: LAASpacing.x2)
            if let interrupt { interrupt }
            sendButton
        }
    }

    private var photoButton: some View {
        PhotosPicker(selection: $photo, matching: .images) {
            LAAGlassActionFace(systemImage: "photo", role: .neutral, enabled: canAttach)
        }
        .disabled(!canAttach)
        .accessibilityLabel(Text(verbatim: "画像を添付"))
        .accessibilityIdentifier("work.composer.photo")
    }

    /// The shared glass button; its colour stays as it was before anything
    /// was typed (owner, 2026-11-12), and it is only disabled when it cannot send.
    private var sendButton: some View {
        LAAGlassActionButton(systemImage: "arrow.up", label: LAACopy.WorkTab.send, role: .send,
                             enabled: canSubmit, identifier: "\(composerPrefix).send", action: submit)
    }

    /// Attached pictures stay above the field as thumbnails (owner,
    /// 2026-11-12: a name alone could not be checked, and a tap removed it).
    /// A tap opens the picture; only the small × takes it off.
    private var chips: some View {
        HStack(spacing: LAASpacing.x3) {
            ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                thumbnail(attachment, index: index)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.composer.attachments")
    }

    private func thumbnail(_ attachment: Attachment, index: Int) -> some View {
        let image = LAAWorkAttachmentImage.image(attachment)
        return Button {
            let images = attachments.compactMap(LAAWorkAttachmentImage.image)
            guard !images.isEmpty else { return }
            let position = attachments.prefix(index).compactMap(LAAWorkAttachmentImage.image).count
            preview = .init(images: images, index: min(position, images.count - 1))
        } label: {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(LAAColor.secondaryText)
                }
            }
            .frame(width: 56, height: 56)
            .background(LAAColor.subtleSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LAAColor.separator, lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: attachment.name))
        .accessibilityHint(Text(verbatim: "全画面で開く"))
        .accessibilityIdentifier("work.composer.attachment.\(index)")
        .overlay(alignment: .topTrailing) {
            Button {
                attachments.removeAll { $0.id == attachment.id }
                saveDraft(text)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LAAColor.text)
                    .frame(width: 20, height: 20)
                    .conduitGlassControl(cornerRadius: 10, interactive: true)
                    // A 20 pt mark with a 32 pt target, off the thumbnail's corner.
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 12, y: -12)
            .accessibilityLabel(Text(verbatim: attachment.name + "を外す"))
            .accessibilityIdentifier("work.composer.attachment.\(index).remove")
        }
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
                            compact: mode == .followUp, focusRequest: focusRequest)
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
            #if DEBUG
            // The UI tests cannot drive the system photo picker: they ask for
            // two drawn pictures instead, through the same path a pick takes.
            if mode == .followUp, attachments.isEmpty,
               ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_WORK_ATTACHMENTS") {
                LAAWorkMessageForm.samplePictures().forEach(addImage)
            }
            #endif
        }
        .onChange(of: quote) { _, request in
            guard let request, mode == .followUp, pending == nil, !sending else { return }
            text = LAAWorkQuoteRequest.inserting(LAAWorkQuoteRequest.markdown(request.text), into: text)
            revision &+= 1
            saveDraft(text)
            focusRequest &+= 1
        }
        .onChange(of: photo) { _, selected in
            Task { @MainActor in
                if let data = try? await selected?.loadTransferable(type: Data.self), let image = UIImage(data: data) { addImage(image) }
                photo = nil
            }
        }
        .laaImagePreview($preview)
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

    #if DEBUG
    static func samplePictures() -> [UIImage] {
        let size = CGSize(width: 1200, height: 900)
        let palettes: [(UIColor, UIColor, String)] = [
            (UIColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1), UIColor(red: 0, green: 0.35, blue: 0.37, alpha: 1), "doc.richtext"),
            (UIColor(red: 0.09, green: 0.15, blue: 0.16, alpha: 1), UIColor(red: 0.89, green: 0.72, blue: 0.40, alpha: 1), "chart.bar.xaxis"),
        ]
        return palettes.map { paper, ink, symbol in
            UIGraphicsImageRenderer(size: size).image { context in
                paper.setFill(); context.fill(CGRect(origin: .zero, size: size))
                ink.setFill()
                context.fill(CGRect(x: 120, y: 140, width: 960, height: 14))
                context.fill(CGRect(x: 120, y: 746, width: 520, height: 14))
                let configuration = UIImage.SymbolConfiguration(pointSize: 300, weight: .light)
                UIImage(systemName: symbol, withConfiguration: configuration)?
                    .withTintColor(ink, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 380, y: 230, width: 440, height: 440))
            }
        }
    }
    #endif

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
            if mode == .followUp { onSent?(item.draft.text, item.draft.attachments) }
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
