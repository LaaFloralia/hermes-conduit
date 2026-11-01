#if LAA_BUILD
import SwiftUI

// Presentation only: the caller supplies confirmed data and owns loading,
// persistence, and navigation. An empty array must mean a completed read.
struct LAAOwnerTaskListContent: View {
    let tasks: [LAAOwnerTask]
    let openTask: (LAAOwnerTask) -> Void
    let createTask: () -> Void
    @State private var doneExpanded = false
    @State private var canceledExpanded = false

    var body: some View {
        let groups = LAAOwnerTaskGroups(tasks: tasks)
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            HStack {
                Text(verbatim: "MY TASKS")
                    .laaTextStyle(.section).fontWeight(.semibold).foregroundStyle(LAAColor.secondaryText)
                Spacer()
                Button("New Task", action: createTask)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("work.ownerTasks.create")
            }
            if groups.open.isEmpty {
                Text(verbatim: "未完了のタスクはありません。")
                    .foregroundStyle(LAAColor.secondaryText).workCard()
            }
            ForEach(groups.open) { task in row(task) }
            DisclosureGroup(isExpanded: $doneExpanded) {
                ForEach(groups.done) { task in row(task) }
            } label: {
                Text(verbatim: "Done (\(groups.done.count))")
            }
            .accessibilityIdentifier("work.ownerTasks.done")
            DisclosureGroup(isExpanded: $canceledExpanded) {
                ForEach(groups.canceled) { task in row(task) }
            } label: {
                Text(verbatim: "Canceled (\(groups.canceled.count))")
            }
            .accessibilityIdentifier("work.ownerTasks.canceled")
        }
        .accessibilityIdentifier("work.ownerTasks")
    }

    private func row(_ task: LAAOwnerTask) -> some View {
        Button { openTask(task) } label: {
            HStack(alignment: .top, spacing: LAASpacing.x3) {
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: task.title).foregroundStyle(LAAColor.text)
                    Text(verbatim: task.status.label)
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
                Spacer(minLength: LAASpacing.x2)
                if let dueDate = task.dueDate {
                    Text(verbatim: dueDate.value)
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .workListRow()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("work.ownerTasks.row.\(task.id.uuidString)")
    }
}

struct LAAOwnerTaskDetailContent: View {
    let task: LAAOwnerTask
    let edit: () -> Void

    var body: some View {
        ZStack {
            LAAColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    Text(verbatim: task.title).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        Text(verbatim: "状態: \(task.status.label)")
                        Text(verbatim: "期限: \(task.dueDate?.value ?? "なし")")
                        Text(verbatim: "作成元: \(task.source.label)")
                        Text(verbatim: "更新: \(task.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    }.workCard()
                    if !task.memo.isEmpty {
                        MarkdownText(source: task.memo, foregroundStyle: LAAColor.text).workCard()
                    }
                    if !task.links.isEmpty {
                        VStack(alignment: .leading, spacing: LAASpacing.x2) {
                            Text(verbatim: "関連リンク").fontWeight(.semibold)
                            ForEach(Array(task.links.enumerated()), id: \.offset) { _, link in
                                if let url = LAAOwnerTaskLink.openableURL(link) {
                                    Link(destination: url) { Text(verbatim: link) }
                                } else {
                                    Text(verbatim: link).textSelection(.enabled)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).workCard()
                    }
                }
                .padding(.horizontal, LAASpacing.horizontal)
                .padding(.vertical, LAASpacing.x4)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
        .navigationTitle("Task")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Edit", action: edit) } }
        .tint(LAAColor.link)
        .accessibilityIdentifier("work.ownerTasks.detail")
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
                    TextField("Title", text: $draft.title, axis: .vertical)
                        .accessibilityIdentifier("work.ownerTasks.editor.title")
                    Picker("Status", selection: $draft.status) {
                        ForEach(LAAOwnerTaskStatus.allCases) { status in
                            Text(verbatim: status.label).tag(status)
                        }
                    }
                    .accessibilityIdentifier("work.ownerTasks.editor.status")
                    TextField("Due Date (YYYY-MM-DD)", text: $draft.dueDateText)
                        .accessibilityIdentifier("work.ownerTasks.editor.dueDate")
                }
                Section("Memo") {
                    TextEditor(text: $draft.memo).frame(minHeight: 150)
                        .accessibilityIdentifier("work.ownerTasks.editor.memo")
                }
                Section {
                    ForEach($linkFields) { $field in
                        HStack {
                            TextField("Link", text: $field.value)
                            Button {
                                let id = field.id
                                linkFields.removeAll { $0.id == id }
                            } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel(Text(verbatim: "Remove Link"))
                        }
                    }
                    Button("Add Link") { linkFields.append(LinkField(value: "")) }
                } header: { Text(verbatim: "Links") }
                if let validationMessage {
                    Section { Text(verbatim: validationMessage).foregroundStyle(LAAColor.attention) }
                }
            }
            .navigationTitle(draft.base == nil ? "New Task" : "Edit Task")
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
        } catch LAAOwnerTaskDraft.ValidationError.invalidDueDate {
            validationMessage = "期限を YYYY-MM-DD で入力するか、空欄にしてください。"
        } catch LAAOwnerTaskDraft.ValidationError.emptyLink {
            validationMessage = "空のリンクを入力するか削除してください。"
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
                Button("Save My Changes to This Version") { saveMine(conflict.rebasedDraft()) }
                    .buttonStyle(.borderedProminent).disabled(!canSaveMine)
                    .accessibilityIdentifier("work.ownerTasks.conflict.saveMine")
                Button("Use Current Version") { confirmUseCurrent = true }
                    .accessibilityIdentifier("work.ownerTasks.conflict.useCurrent")
                Button("Keep Draft", action: keepDraft)
                    .accessibilityIdentifier("work.ownerTasks.conflict.keep")
            }
            .padding(.horizontal, LAASpacing.horizontal)
            .padding(.vertical, LAASpacing.x4)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle("Compare Changes")
        .confirmationDialog("現在の内容を使いますか？", isPresented: $confirmUseCurrent, titleVisibility: .visible) {
            Button("自分の入力を破棄して現在の内容を使う", role: .destructive, action: useCurrent)
            Button("Keep Draft", role: .cancel) { }
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
