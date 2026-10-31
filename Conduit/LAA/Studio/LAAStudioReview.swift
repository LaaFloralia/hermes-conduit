#if LAA_BUILD
import SwiftUI
import UIKit

struct LAAStudioReviewView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let snapshot: LAAStudioSnapshot
    let project: LAAStudioProject
    let target: LAAStudioReview.Target
    let targetName: String
    let revision: Int
    let reviews: [LAAStudioReview]
    var unavailableInListing = false
    @State private var state = LAAStudioReviewEditorState()
    @State private var initialized = false
    @State private var storageError = false
    @State private var sending = false
    @State private var canEditAgain = false
    @State private var error: String?
    @State private var completed: LAAStudioReview?
    @State private var copied = false
    private var device: String { bridge.deviceID ?? "fixture" }
    private var history: [LAAStudioReview] {
        LAAStudioReview.history(reviews, target: target, including: completed)
    }
    private var canSubmit: Bool {
        !storageError && !sending && state.pending == nil && LAAStudioReview.canSubmit(verdict: state.verdict, comment: state.comment)
    }
    private var verdict: Binding<String> {
        Binding(get: { state.verdict ?? "" }, set: { state.verdict = $0.isEmpty ? nil : $0 })
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LAASpacing.x4) {
                Text(verbatim: targetName).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                Text(verbatim: "講評は記録です。作品や納品は変更されません。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                if unavailableInListing {
                    Text(verbatim: "この版は取得した最新50件にありません。下書きの対象は元の版のままです。別の版への講評には内容をコピーしてください。")
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    if !state.comment.isEmpty {
                        Button {
                            UIPasteboard.general.string = state.comment
                            copied = true
                        } label: {
                            Text(verbatim: copied ? "コメントをコピーしました" : "コメントをコピー").frame(minHeight: LAASpacing.minimumTouchTarget)
                        }
                    }
                }
                if let completed {
                    Text(verbatim: "講評を保存しました。").foregroundStyle(LAAColor.text)
                    if completed.verdict == "revise" {
                        NavigationLink {
                            LAAStudioCreateView(snapshot: snapshot, initialProject: project,
                                                initialPrompt: "以下の講評を踏まえて修正してください。\n\(completed.comment ?? "")",
                                                draftID: completed.id)
                        } label: {
                            Text(verbatim: "修正依頼の下書きを開く").frame(minHeight: LAASpacing.minimumTouchTarget)
                        }
                    }
                } else {
                    if state.pending != nil {
                        Text(verbatim: canEditAgain ? "今回の送信は受け付けられませんでした。内容を保持しています。" : "送信結果を確認できていません。同じ講評を照合または再送できます。")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    }
                    Picker("判定", selection: verdict) {
                        Text(verbatim: "判定なし").tag("")
                        Text(verbatim: "採用").tag("adopt")
                        Text(verbatim: "直す").tag("revise")
                        Text(verbatim: "不採用").tag("reject")
                    }.pickerStyle(.segmented).disabled(state.pending != nil || sending || storageError)
                    Text(verbatim: "コメント").laaTextStyle(.section).fontWeight(.semibold)
                    TextEditor(text: $state.comment)
                        .frame(minHeight: 140).padding(LAASpacing.x2)
                        .background(LAAColor.subtleSurface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                        .disabled(state.pending != nil || sending || storageError)
                        .accessibilityIdentifier("laa.studio.review.comment")
                    Text(verbatim: "\(state.comment.utf16.count) / 4,000")
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    if state.pending == nil {
                        Button { Task { await submit(retry: false) } } label: {
                            Text(verbatim: "講評を保存").frame(minHeight: LAASpacing.minimumTouchTarget)
                        }.buttonStyle(.borderedProminent).tint(LAAColor.filledButton).disabled(!canSubmit)
                            .accessibilityIdentifier("laa.studio.review.send")
                    } else {
                        Button { Task { await check() } } label: {
                            Text(verbatim: "保存状態を確認").frame(minHeight: LAASpacing.minimumTouchTarget)
                        }.disabled(sending || storageError)
                        Button { Task { await submit(retry: true) } } label: {
                            Text(verbatim: "同じ講評を再送").frame(minHeight: LAASpacing.minimumTouchTarget)
                        }.disabled(sending || storageError).accessibilityIdentifier("laa.studio.review.retry")
                        if canEditAgain {
                            Button {
                                var editable = state; editable.pending = nil
                                guard LAAStudioReviewStore.save(editable, deviceID: device, projectID: project.id, target: target,
                                                                targetName: targetName, revision: revision) else {
                                    storageError = true; return
                                }
                                state = editable; canEditAgain = false; error = nil
                            } label: {
                                Text(verbatim: "入力し直す").frame(minHeight: LAASpacing.minimumTouchTarget)
                            }.disabled(sending || storageError)
                        }
                    }
                }
                if storageError { Text(verbatim: "下書きを読み書きできません。保存済みの内容を保持するため送信を止めています。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                if let error { Text(verbatim: error).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                if sending { ProgressView().accessibilityLabel(Text(verbatim: LAACopy.loading)) }
                Divider()
                Text(verbatim: "履歴").laaTextStyle(.section).fontWeight(.semibold)
                Text(verbatim: "作品の講評は新しいものから最大200件を表示します。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                if history.isEmpty { Text(verbatim: "取得した範囲に講評はありません。").foregroundStyle(LAAColor.secondaryText) }
                ForEach(Array(history.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        Text(verbatim: "\(index == 0 ? "現行 · " : "")\(Self.label(item.verdict)) · Revision \(item.revision)")
                            .laaTextStyle(.body).fontWeight(.semibold)
                        if let comment = item.comment, !comment.isEmpty { Text(verbatim: comment).laaTextStyle(.body) }
                        Text(verbatim: LAAWorkPresentation.date(item.createdAt)).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        if item.verdict == "revise" && item.id != completed?.id {
                            NavigationLink {
                                LAAStudioCreateView(snapshot: snapshot, initialProject: project,
                                                    initialPrompt: "以下の講評を踏まえて修正してください。\n\(item.comment ?? "")",
                                                    draftID: item.id)
                            } label: {
                                Text(verbatim: "修正依頼の下書きを開く").frame(minHeight: LAASpacing.minimumTouchTarget)
                            }
                        }
                    }.padding(LAASpacing.x3).frame(maxWidth: .infinity, alignment: .leading)
                        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                }
            }.padding(LAASpacing.horizontal).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: "講評"))
            .navigationBarTitleDisplayMode(.inline).tint(LAAColor.link)
            .onAppear(perform: restore)
            .onChange(of: state) { _, value in
                guard initialized, completed == nil, !storageError else { return }
                if !LAAStudioReviewStore.save(value, deviceID: device, projectID: project.id, target: target,
                                              targetName: targetName, revision: revision) { storageError = true }
            }
    }
    static func label(_ value: String?) -> String {
        switch value {
        case "adopt": return "採用"
        case "revise": return "直す"
        case "reject": return "不採用"
        default: return "コメント"
        }
    }
    @MainActor private func restore() {
        guard !initialized else { return }
        switch LAAStudioReviewStore.load(deviceID: device, projectID: project.id, target: target) {
        case .missing: break
        case .loaded(let value):
            state = value
            if !LAAStudioReviewStore.save(value, deviceID: device, projectID: project.id, target: target,
                                          targetName: targetName, revision: revision) { storageError = true }
        case .unreadable: storageError = true
        }
        initialized = true
    }
    @MainActor private func submit(retry: Bool) async {
        guard !sending, !storageError else { return }
        sending = true; error = nil; canEditAgain = false
        defer { sending = false }
        do {
            var draft: LAAStudioReviewDraft
            if retry {
                guard let previous = state.pending, previous.intact else { return }
                draft = previous
                draft.rotateKey()
            } else {
                guard canSubmitIgnoringSending else { error = LAACopy.Studio.invalid; return }
                let id = try await LAAStudioData.requestID(bridge)
                let comment = state.comment.trimmingCharacters(in: .whitespacesAndNewlines)
                let review = LAAStudioReview(id: id, projectId: project.id, revision: revision, target: target,
                                             verdict: state.verdict, comment: comment.isEmpty ? nil : comment)
                draft = try LAAStudioReviewDraft(review: review)
            }
            draft.pending = true
            var savedState = state; savedState.pending = draft
            guard LAAStudioReviewStore.save(savedState, deviceID: device, projectID: project.id, target: target,
                                            targetName: targetName, revision: revision),
                  let key = draft.submissionKey else { storageError = true; return }
            state = savedState
            let saved = try await LAAStudioData.review(draft.review, body: draft.body, key: key, bridge: bridge)
            finish(saved)
        } catch let failure as LAABridgeHTTPError {
            canEditAgain = LAAStudioReviewDraft.definitelyRejected(failure)
            self.error = LAAStudioData.message(failure)
        } catch { self.error = LAAStudioData.message(error) }
    }
    private var canSubmitIgnoringSending: Bool {
        state.pending == nil && LAAStudioReview.canSubmit(verdict: state.verdict, comment: state.comment)
    }
    @MainActor private func check() async {
        guard !sending, let draft = state.pending else { return }
        sending = true; error = nil
        defer { sending = false }
        do {
            let detail = try await LAAStudioData.project(project.id, bridge: bridge)
            if let found = detail.reviews.first(where: { $0.id == draft.review.id }) {
                guard found.createdAt != nil, draft.review.sameSubmission(as: found) else {
                    error = "同じIDの講評の内容が一致しません。Macで確認してください。"; return
                }
                finish(found)
            } else {
                if target.kind == "version", !detail.versions.contains(where: { $0.id == target.id }) {
                    error = "最新200件に講評がなく、対象の版も最新50件にありません。保存の有無は未確定です。同じ講評を再送できます。"
                } else {
                    error = "最新200件には見つかりません。保存されていないとは限りません。同じ講評を再送できます。"
                }
            }
        } catch { self.error = LAAStudioData.message(error) }
    }
    @MainActor private func finish(_ review: LAAStudioReview) {
        completed = review
        if !LAAStudioReviewStore.clear(deviceID: device, projectID: project.id, target: target) {
            error = "講評は保存されましたが、この端末の送信記録を片付けられませんでした。"
        }
    }
}
#endif
