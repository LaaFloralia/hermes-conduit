#if LAA_BUILD
import SwiftUI

struct LAABrainManageNoteView: View {
    @Environment(\.dismiss) private var dismiss
    let root: URL
    let note: LAABrainNote
    let completed: (String) -> Void
    @State private var name = ""
    @State private var folders: [String] = []
    @State private var folder = ""
    @State private var busy = false
    @State private var confirmTrash = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $name) { Text(verbatim: "名前") }
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("laa.brain.manage.name")
                    Picker(selection: $folder) {
                        Text(verbatim: "Brain直下").tag("")
                        ForEach(folders, id: \.self) { Text(verbatim: $0).tag($0) }
                    } label: { Text(verbatim: "保存先") }
                    Text(verbatim: "本文はそのまま移動します。相対リンクや、このノートへのリンクは自動変更されません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { perform(trash: false) } label: { Text(verbatim: "移動・名前変更") }
                        .disabled(name.isEmpty || busy)
                        .accessibilityIdentifier("laa.brain.manage.move")
                }
                Section {
                    Button(role: .destructive) { confirmTrash = true } label: { Text(verbatim: "ゴミ箱へ移動") }
                        .accessibilityIdentifier("laa.brain.manage.trash")
                    Text(verbatim: ".trashに移動し、復元履歴にも残します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let failure { Text(verbatim: failure).foregroundStyle(LAAColor.attention) }
                if busy { ProgressView() }
            }
            .disabled(busy)
            .navigationTitle(Text(verbatim: "ノートの管理"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(verbatim: "閉じる") }.disabled(busy)
                }
            }
            .confirmationDialog(Text(verbatim: "このノートをゴミ箱へ移動しますか？"), isPresented: $confirmTrash, titleVisibility: .visible) {
                Button(role: .destructive) { perform(trash: true) } label: { Text(verbatim: "ゴミ箱へ移動") }
                    .accessibilityIdentifier("laa.brain.manage.confirmTrash")
                Button(role: .cancel) {} label: { Text(verbatim: "キャンセル") }
            }
        }
        .interactiveDismissDisabled(busy)
        .task {
            name = URL(fileURLWithPath: note.path).deletingPathExtension().lastPathComponent
            folder = note.path.split(separator: "/").dropLast().joined(separator: "/")
            do {
                folders = try await Task.detached { try LAABrainVaultIO.listing(root: root).folders.sorted() }.value
            } catch { failure = "保存先を読み込めません。フォルダへのアクセスを確認してください。" }
        }
    }

    private func perform(trash: Bool) {
        busy = true; failure = nil
        let inputName = name, parent = folder
        Task {
            do {
                let destination = try await Task.detached(priority: .userInitiated) {
                    let destination: String
                    if trash { destination = ".trash/" + UUID().uuidString + "-" + URL(fileURLWithPath: note.path).lastPathComponent }
                    else {
                        let finalName = try LAABrainFolderStore.itemName(inputName, kind: .note)
                        destination = parent.isEmpty ? finalName : parent + "/" + finalName
                    }
                    let snapshot = LAABrainSaveCoordinator.Snapshot(vault: LAABrainSaveJournal.vaultID(root),
                                                                   path: note.path, base: Data(note.text.utf8))
                    return try LAABrainSaveCoordinator().relocate(root: root, snapshot: snapshot, destination: destination, toTrash: trash)
                }.value
                busy = false; completed(destination)
            } catch LAABrainSaveCoordinator.SaveError.sourceChanged {
                busy = false; failure = "別の変更があります。閉じてノートを読み直してください。両方の内容は復元履歴に残ります。"
            } catch LAABrainSaveCoordinator.SaveError.destinationExists {
                busy = false; failure = "同名のノートがあります。別の名前を選んでください。"
            } catch {
                busy = false; failure = "操作を完了できません。元と保存先の両方を確認してください。自動再試行は行いません。"
            }
        }
    }
}
#endif
