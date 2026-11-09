#if LAA_BUILD
import SwiftUI

// LAA's owner-specific explanatory copy is Japanese, like the rest of Work's
// body text. Shared control labels use the app's translated catalog keys.
enum LAAOwnerTaskCopy {
    static let addTask = "タスクを追加"
    static let editTask = "タスクを編集"
    static let setDueDate = "期限を設定"
    static let addLink = "リンクを追加"
    static let saveMine = "自分の変更をこの内容に保存"
    static let useCurrent = "現在の内容を使う"
    static let keepDraft = "下書きを残す"
    static let compare = "変更を比較"
    static let confirmUseCurrent = "現在の内容を使いますか？"
    static let discardAndUseCurrent = "自分の入力を破棄して現在の内容を使う"
    static let restoreCanceled = "取消から未完了に戻す"
    static let cancelTask = "タスクを取り消す"
    static let inspectCurrent = "現在を確認"
    static let discard = "破棄"
    static let otherDevices = "別の端末・別の本人"
    static let move = "移す"
    static let pending = "送信待ち・下書き"
    static let confirmAction = "選択した操作を確認"
    static let retryRequest = "再送する"
    static let discardRecord = "端末の記録を破棄"
    static let moveToDevice = "この端末へ移す"
    static let moveDraft = "この端末の下書きへ移す"
    static let discardLocalDraft = "端末の下書きを破棄"
}

// Presentation only: the caller supplies confirmed data and owns loading,
// persistence, and navigation. An empty array must mean a completed read.
struct LAAOwnerTaskListContent: View {
    let tasks: [LAAOwnerTask]
    @Binding var newTitle: String
    let adding: Bool
    let inputEnabled: Bool
    let showEmpty: Bool
    let disabledIDs: Set<UUID>
    let checkboxDisabledIDs: Set<UUID>
    let openTask: (LAAOwnerTask) -> Void
    let createTask: () -> Void
    let toggleTask: (LAAOwnerTask) -> Void
    @State private var doneExpanded = false
    @State private var canceledExpanded = false

    var body: some View {
        let groups = LAAOwnerTaskGroups(tasks: tasks)
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            HStack(spacing: LAASpacing.x2) {
                Image(systemName: "plus").foregroundStyle(LAAColor.link)
                TextField(LAAOwnerTaskCopy.addTask, text: $newTitle)
                    .submitLabel(.done)
                    .onSubmit(createTask)
                    .disabled(!inputEnabled)
                    .accessibilityIdentifier("work.ownerTasks.newTitle")
                Button("Add", action: createTask)
                    .disabled(!inputEnabled || adding || newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("work.ownerTasks.create")
            }
            .workCard()
            if showEmpty && groups.open.isEmpty {
                Text(verbatim: "未完了のタスクはありません。")
                    .foregroundStyle(LAAColor.secondaryText).workCard()
            }
            ForEach(groups.open) { task in row(task) }
            if showEmpty || !tasks.isEmpty {
                DisclosureGroup(isExpanded: $doneExpanded) {
                    ForEach(groups.done) { task in row(task) }
                } label: {
                    Text(verbatim: "完了済み（\(groups.done.count)）")
                }
                .accessibilityIdentifier("work.ownerTasks.done")
                DisclosureGroup(isExpanded: $canceledExpanded) {
                    ForEach(groups.canceled) { task in row(task) }
                } label: {
                    Text(verbatim: "取消済み（\(groups.canceled.count)）")
                }
                .accessibilityIdentifier("work.ownerTasks.canceled")
            }
        }
        .accessibilityIdentifier("work.ownerTasks")
    }

    private func row(_ task: LAAOwnerTask) -> some View {
        HStack(alignment: .center, spacing: LAASpacing.x2) {
            Button { toggleTask(task) } label: {
                Image(systemName: task.status == .done ? "checkmark.square.fill" : "square")
                    .font(.title3).foregroundStyle(LAAColor.link)
                    .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
            }
            .buttonStyle(.plain)
            .disabled(disabledIDs.contains(task.id) || checkboxDisabledIDs.contains(task.id))
            .accessibilityLabel(Text(verbatim: task.status == .done ? "未完了に戻す" : "完了にする"))
            .accessibilityValue(Text(verbatim: task.title))
            .accessibilityIdentifier("work.ownerTasks.check.\(task.id.uuidString)")
            Button { openTask(task) } label: {
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: task.title).foregroundStyle(LAAColor.text)
                    if let dueDate = task.dueDate {
                        Text(verbatim: "期限 \(dueDate.value)")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                    if task.status == .doing {
                        Text(verbatim: "進行中").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabledIDs.contains(task.id))
            .accessibilityHint(Text(verbatim: "タップして編集"))
            .accessibilityIdentifier("work.ownerTasks.row.\(task.id.uuidString)")
        }
        .workListRow()
    }
}

struct LAAOwnerTaskEditor: View {
    private struct LinkField: Identifiable {
        let id = UUID()
        var value: String
    }

    @Environment(\.dismiss) private var dismiss
    @State private var draft: LAAOwnerTaskDraft
    @State private var linkFields: [LinkField]
    @State private var validationMessage: String?
    let onChange: (LAAOwnerTaskDraft) -> Void
    let save: (LAAOwnerTaskDraft) -> Void

    init(draft: LAAOwnerTaskDraft, onChange: @escaping (LAAOwnerTaskDraft) -> Void,
         save: @escaping (LAAOwnerTaskDraft) -> Void) {
        _draft = State(initialValue: draft)
        _linkFields = State(initialValue: draft.links.map { LinkField(value: $0) })
        self.onChange = onChange
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $draft.title)
                        .accessibilityIdentifier("work.ownerTasks.editor.title")
                    Toggle(LAAOwnerTaskCopy.setDueDate, isOn: dueDateEnabled)
                    if !draft.dueDateText.isEmpty {
                        DatePicker("Due date", selection: dueDate, displayedComponents: .date)
                            .accessibilityIdentifier("work.ownerTasks.editor.dueDate")
                    }
                }
                Section("Note") {
                    TextEditor(text: $draft.memo).frame(minHeight: 150)
                        .accessibilityIdentifier("work.ownerTasks.editor.memo")
                }
                Section {
                    ForEach($linkFields) { $field in
                        HStack {
                            TextField("Link", text: $field.value)
                            if let url = LAAOwnerTaskLink.openableURL(field.value) {
                                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                                    .accessibilityLabel(Text(verbatim: "リンクを開く"))
                            }
                            Button {
                                let id = field.id
                                linkFields.removeAll { $0.id == id }
                            } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel(Text(verbatim: "リンクを外す"))
                        }
                    }
                    Button(LAAOwnerTaskCopy.addLink) { linkFields.append(LinkField(value: "")) }
                } header: { Text(verbatim: "関連リンク") }
                if let task = draft.base {
                    Section("Details") {
                        Text(verbatim: "作成元: \(task.source.label)")
                        Text(verbatim: "更新: \(task.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                if draft.base != nil {
                    Section {
                        Button(draft.status == .canceled ? LAAOwnerTaskCopy.restoreCanceled : LAAOwnerTaskCopy.cancelTask) {
                            draft.status = draft.status == .canceled ? .todo : .canceled
                            saveIfValid()
                        }
                    }
                }
                if let validationMessage {
                    Section { Text(verbatim: validationMessage).foregroundStyle(LAAColor.attention) }
                }
            }
            .navigationTitle(draft.base == nil ? LAAOwnerTaskCopy.addTask : LAAOwnerTaskCopy.editTask)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveIfValid() }
                        .accessibilityIdentifier("work.ownerTasks.editor.save")
                }
            }
            .onChange(of: draft) { _, _ in publishDraft() }
            .onChange(of: linkFields.map(\.value)) { _, _ in publishDraft() }
        }
        .accessibilityIdentifier("work.ownerTasks.editor")
    }

    private var dueDateEnabled: Binding<Bool> {
        Binding(get: { !draft.dueDateText.isEmpty }, set: { enabled in
            draft.dueDateText = enabled ? Self.dayString(Date()) : ""
        })
    }

    private var dueDate: Binding<Date> {
        Binding(get: {
            let parts = draft.dueDateText.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return Date() }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
        }, set: { draft.dueDateText = Self.dayString($0) })
    }

    private static func dayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func currentDraft() -> LAAOwnerTaskDraft {
        var result = draft
        result.links = linkFields.map(\.value)
        return result
    }

    private func publishDraft() { onChange(currentDraft()) }

    private func saveIfValid() {
        let result = currentDraft()
        do {
            try result.validate()
            validationMessage = nil
            save(result)
        } catch LAAOwnerTaskDraft.ValidationError.missingTitle {
            validationMessage = "題名を入力してください。"
        } catch LAAOwnerTaskDraft.ValidationError.invalidTitle {
            validationMessage = "題名は改行を含めず500文字以内で入力してください。"
        } catch LAAOwnerTaskDraft.ValidationError.invalidMemo {
            validationMessage = "メモは20,000文字以内で入力してください。"
        } catch LAAOwnerTaskDraft.ValidationError.invalidDueDate {
            validationMessage = "期限を YYYY-MM-DD で入力するか、空欄にしてください。"
        } catch LAAOwnerTaskDraft.ValidationError.emptyLink {
            validationMessage = "空のリンクにURLを入力するか、リンクを外してください。"
        } catch LAAOwnerTaskDraft.ValidationError.invalidLink {
            validationMessage = "関連リンクは http または https のURLで入力してください。"
        } catch {
            validationMessage = "入力内容を確認してください。"
        }
    }
}

struct LAAOwnerTaskConflictContent: View {
    let conflict: LAAOwnerTaskConflict
    let useCurrent: () -> Void
    let saveMine: (LAAOwnerTaskDraft) -> Void
    let keepDraft: () -> Void
    @State private var confirmUseCurrent = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                Text(verbatim: "保存中にタスクが更新されました。変更した項目を比較して選んでください。")
                if conflict.changedFields.isEmpty {
                    Text(verbatim: "自分で変更した項目はありません。")
                        .foregroundStyle(LAAColor.secondaryText)
                }
                ForEach(conflict.changedFields) { field in
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        Text(verbatim: field.label).fontWeight(.semibold)
                        Text(verbatim: "現在の内容").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        value(conflict.currentValue(for: field))
                        Text(verbatim: "自分の入力").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        value(conflict.draftValue(for: field))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .workCard()
                    .accessibilityIdentifier("work.ownerTasks.conflict.\(field.rawValue)")
                }
                Text(verbatim: "自分の変更を保存する場合、変更していない項目には現在の内容を使います。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                Button(LAAOwnerTaskCopy.saveMine) { saveMine(conflict.rebasedDraft()) }
                    .laaGlassButton(prominent: true).disabled(!canSaveMine)
                    .accessibilityIdentifier("work.ownerTasks.conflict.saveMine")
                Button(LAAOwnerTaskCopy.useCurrent) { confirmUseCurrent = true }
                    .accessibilityIdentifier("work.ownerTasks.conflict.useCurrent")
                Button(LAAOwnerTaskCopy.keepDraft, action: keepDraft)
                    .accessibilityIdentifier("work.ownerTasks.conflict.keep")
            }
            .padding(.horizontal, LAASpacing.horizontal)
            .padding(.vertical, LAASpacing.x4)
            .laaPageWidth()
        }
        .navigationTitle(LAAOwnerTaskCopy.compare)
        .confirmationDialog(LAAOwnerTaskCopy.confirmUseCurrent, isPresented: $confirmUseCurrent, titleVisibility: .visible) {
            Button(LAAOwnerTaskCopy.discardAndUseCurrent, role: .destructive, action: useCurrent)
            Button(LAAOwnerTaskCopy.keepDraft, role: .cancel) { }
        } message: {
            Text(verbatim: "自分の入力は端末から破棄されます。")
        }
        .accessibilityIdentifier("work.ownerTasks.conflict")
    }

    private var canSaveMine: Bool {
        guard !conflict.changedFields.isEmpty else { return false }
        do { try conflict.rebasedDraft().validate(); return true } catch { return false }
    }

    private func value(_ text: String) -> some View {
        Text(verbatim: text.isEmpty ? "（なし）" : text).textSelection(.enabled)
    }
}
#endif
