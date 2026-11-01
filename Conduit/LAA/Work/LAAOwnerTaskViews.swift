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
    let save: (LAAOwnerTaskDraft) -> Void

    init(task: LAAOwnerTask?, save: @escaping (LAAOwnerTaskDraft) -> Void) {
        let draft = LAAOwnerTaskDraft(task: task)
        _draft = State(initialValue: draft)
        _linkFields = State(initialValue: draft.links.map { LinkField(value: $0) })
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveIfValid() }
                        .accessibilityIdentifier("work.ownerTasks.editor.save")
                }
            }
        }
        .accessibilityIdentifier("work.ownerTasks.editor")
    }

    private func saveIfValid() {
        var result = draft
        result.links = linkFields.map(\.value)
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
#endif
