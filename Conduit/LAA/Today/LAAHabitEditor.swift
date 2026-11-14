#if LAA_BUILD
import SwiftUI
struct LAAHabitEditor: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let habit: LAAHabit?
    @ObservedObject var model: LAAHabitsModel
    @State private var current: LAAHabit?
    @State private var kind: String
    @State private var title: String
    @State private var target: Int
    @State private var minutes: String
    @State private var minimum: String
    @State private var support: String
    @State private var note: String
    @State private var busy = false
    @State private var message: String?
    @State private var confirmArchive = false
    @State private var key = LAABridgeIdempotencyKey()
    @State private var submitted: Data?
    init(habit: LAAHabit?, model: LAAHabitsModel) {
        self.habit = habit; self.model = model
        _current = State(initialValue: habit); _kind = State(initialValue: habit?.kind ?? "do")
        _title = State(initialValue: habit?.title ?? ""); _target = State(initialValue: habit?.weeklyTarget ?? 3)
        _minutes = State(initialValue: habit?.minutes.map(String.init) ?? "")
        _minimum = State(initialValue: habit?.minimum ?? ""); _support = State(initialValue: habit?.support ?? "ask"); _note = State(initialValue: habit?.note ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $kind) { Text(verbatim: "習慣").tag("do"); Text(verbatim: "禁止習慣").tag("avoid") } label: { Text(verbatim: "種類") }.disabled(habit != nil).accessibilityIdentifier("laa.habits.kind")
                    LabeledContent {
                        TextField(text: $title, prompt: Text(verbatim: "")) { Text(verbatim: "名前") }
                            .multilineTextAlignment(.trailing).accessibilityIdentifier("laa.habits.title")
                    } label: { Text(verbatim: "名前") }
                    Stepper(value: $target, in: (kind == "do" ? 1 : 0)...7) { Text(verbatim: kind == "do" ? "週\(target)日" : (target == 0 ? "しない" : "週\(target)日まで")) }.accessibilityIdentifier("laa.habits.target")
                    LabeledContent {
                        HStack(spacing: LAASpacing.x1) {
                            TextField(text: $minutes, prompt: Text(verbatim: "任意")) { Text(verbatim: "1回の目安") }
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            Text(verbatim: "分").foregroundStyle(LAAColor.secondaryText)
                        }
                    } label: { Text(verbatim: "1回の目安") }
                    LabeledContent {
                        TextField(text: $minimum, prompt: Text(verbatim: "任意"), axis: .vertical) { Text(verbatim: "余力がない日の最小の形") }
                            .multilineTextAlignment(.trailing)
                    } label: { Text(verbatim: "最小の形") }
                }
                Section {
                    Picker(selection: $support) {
                        Text(verbatim: "見せない").tag("off"); Text(verbatim: "聞いた時だけ").tag("ask"); Text(verbatim: "提案に含める").tag("plan")
                    } label: { Text(verbatim: "Monetの支援") }
                    Text(verbatim: support == "off" ? "Monetに内容が渡りません" : support == "ask" ? "社長が聞いた時だけMonetが読みます" : "今日の一手と週の振り返りに含めます").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                }
                Section {
                    LabeledContent {
                        TextField(text: $note, prompt: Text(verbatim: "任意"), axis: .vertical) { Text(verbatim: "メモ") }
                            .lineLimit(1...8).multilineTextAlignment(.trailing)
                    } label: { Text(verbatim: "メモ") }
                }
                if let message { LAAInlineFailure(reason: message) { Task { await save() } } }
                if habit != nil {
                    Section {
                        Button { confirmArchive = true } label: { Text(verbatim: "この習慣をやめる") }.accessibilityIdentifier("laa.habits.archive")
                    }
                }
            }.disabled(busy).scrollContentBackground(.hidden).background(LAAColor.background).laaTextStyle(.body)
                .navigationTitle(Text(verbatim: habit == nil ? "習慣を追加" : "習慣を編集")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(verbatim: "キャンセル") }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { Button { Task { await save() } } label: { Text(verbatim: "保存") }.disabled(!valid || busy).accessibilityIdentifier("laa.habits.save") }
                }
                .confirmationDialog(Text(verbatim: "この習慣をやめますか？"), isPresented: $confirmArchive, titleVisibility: .visible) {
                    Button { Task { await save(archive: true) } } label: { Text(verbatim: "やめる") }.accessibilityIdentifier("laa.habits.archive.confirm")
                } message: { Text(verbatim: "記録は残り、履歴から戻せます") }
        }.interactiveDismissDisabled(busy).onChange(of: kind) { _, kind in if kind == "do" { target = max(1, target) } }
    }
    private var valid: Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 80 && minimum.count <= 80 && note.count <= 500 && (minutes.isEmpty || Int(minutes).map { (1...600).contains($0) } == true)
    }
    private func save(archive: Bool = false) async {
        guard !busy else { return }; busy = true; message = nil; defer { busy = false }
        do {
            var fields: [String: Any] = archive ? ["archived": true] : ["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "weeklyTarget": target, "minutes": Int(minutes).map { $0 as Any } ?? NSNull(), "minimum": minimum.isEmpty ? NSNull() : minimum as Any, "support": support, "note": note]
            if habit == nil { fields["kind"] = kind }
            let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            // A retry keeps the original key and body. Changing fields creates a new operation.
            if submitted != nil && submitted != body { key = LAABridgeIdempotencyKey() }
            submitted = body
            if let current { _ = try await model.update(current, body: body, bridge: bridge) }
            else {
                let _: LAABridgeResponse<LAAHabit> = try await bridge.request(method: "POST", path: "/v1/habits", jsonBody: body, idempotencyKey: key)
            }
            await model.refresh(bridge); await model.loadHistory(bridge); dismiss()
        } catch {
            if (error as? LAABridgeHTTPError)?.status == 412 {
                await model.refresh(bridge); await model.loadHistory(bridge)
                if let updated = model.value?.items.first(where: { $0.id == habit?.id }) ?? model.archived.first(where: { $0.id == habit?.id }) {
                    current = updated; title = updated.title; target = updated.weeklyTarget; minutes = updated.minutes.map(String.init) ?? ""; minimum = updated.minimum ?? ""; support = updated.support; note = updated.note
                }
                message = "ほかで変更されました。読み直した内容を確認してください"
            } else { message = "保存できませんでした。入力内容を確認して、もう一度お試しください" }
        }
    }
}
#endif
