#if LAA_BUILD
import SwiftUI

/// The Bridge uses the existing IME-safe field and full editor; it never sends
/// through ComposerBar or the Hermes AppState.
struct LAAWorkComposer: View {
    @Binding var text: String
    @Binding var revision: UInt64
    let placeholder: String
    let enabled: Bool
    var canSend = true
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    var submitLabel = LAACopy.WorkTab.send
    var accessibilityPrefix = "work.composer"

    @State private var focus = false
    @State private var height = ComposerPasteTextView.minimumHeight
    @State private var editorIdentity = UUID()
    @State private var fullEditor = false
    @State private var warning: String?
    @AppStorage(ChatTypography.inputPreferenceKey) private var inputSize = ChatTypography.defaultInputSize.rawValue

    private var canSubmit: Bool { enabled && canSend && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack {
                Text(verbatim: placeholder).laaTextStyle(.body).fontWeight(.semibold)
                Spacer()
                Menu {
                    Picker(LAACopy.WorkTab.textSize, selection: $inputSize) {
                        ForEach(ChatTextSize.allCases, id: \.rawValue) { size in
                            Text(verbatim: size.displayName).tag(size.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "textformat.size")
                        .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                }
                    .accessibilityLabel(Text(verbatim: LAACopy.WorkTab.textSize))
                Button { fullEditor = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                }
                    .accessibilityLabel(Text(verbatim: LAACopy.WorkTab.fullEditor))
                    .accessibilityIdentifier("\(accessibilityPrefix).expand")
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(verbatim: placeholder).foregroundStyle(LAAColor.secondaryText)
                        .padding(.horizontal, LAASpacing.x2).padding(.vertical, LAASpacing.x2).allowsHitTesting(false)
                }
                ComposerPasteTextView(
                    text: $text, isFocused: $focus, measuredHeight: $height, enabled: enabled,
                    onPastedImage: { _ in warning = "セッションへの画像添付はまだ対応していません。" },
                    onPastedImageError: { _ in warning = "画像を追加できません。" },
                    editorIdentity: editorIdentity,
                    inputTextSize: ChatTypography.inputSize(rawValue: inputSize),
                    programmaticRevision: revision
                )
                .frame(height: height)
                .accessibilityIdentifier("\(accessibilityPrefix).field")
            }
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            .overlay(RoundedRectangle(cornerRadius: LAARadius.card).stroke(LAAColor.separator))
            if let warning { Text(verbatim: warning).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
            HStack {
                Spacer()
                Button(submitLabel, action: onSubmit)
                    .buttonStyle(.borderedProminent).tint(LAAColor.filledButton)
                    .foregroundStyle(LAAColor.filledButtonText).disabled(!canSubmit)
                    .accessibilityIdentifier("\(accessibilityPrefix).send")
            }
        }
        .onChange(of: text) { _, value in onChange(value) }
        .sheet(isPresented: $fullEditor, onDismiss: { revision &+= 1 }) {
            ComposerFullEditor(
                text: $text, placeholder: placeholder, programmaticRevision: revision,
                fieldIdentifier: "\(accessibilityPrefix).fullEditor.field", enabled: enabled,
                onUserEdit: { _ in }, onCollapse: { fullEditor = false },
                canSubmitFromReturn: false, onSubmitFromReturn: { false },
                attachments: { EmptyView() }, dictateButton: { EmptyView() },
                actionButton: {
                    Button(submitLabel) { fullEditor = false; onSubmit() }
                        .buttonStyle(.borderedProminent).tint(LAAColor.filledButton)
                        .foregroundStyle(LAAColor.filledButtonText).disabled(!canSubmit)
                }
            )
        }
    }
}

/// Preserve the fact that a particular Project write was rejected with 412.
/// A merely unknown write must never be replaced with a new key, even after an
/// app restart. The marker contains no Project content or credential.
enum LAAWorkConflictJournal {
    static var directory: URL {
        LAAWorkDrafts.fileURL.deletingLastPathComponent().appendingPathComponent("project-conflicts", isDirectory: true)
    }
    static func contains(_ id: UUID, in folder: URL = directory) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString).path)
    }
    static func mark(_ id: UUID, in folder: URL = directory) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("412".utf8).write(to: folder.appendingPathComponent(id.uuidString),
                                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }
    static func clear(_ id: UUID, in folder: URL = directory) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id.uuidString))
    }
}
#endif
