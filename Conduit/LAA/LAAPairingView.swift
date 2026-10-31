#if LAA_BUILD
import SwiftUI

struct LAAPairingView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var isPairing = false
    @State private var failure: LAABridgeError?

    /// The code as the Bridge should see it: pasting from `laa-bridge pair`
    /// can carry a newline or spaces, which must not fail the match.
    static func normalizedCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var submittedCode: String { Self.normalizedCode(code) }

    private var canPair: Bool {
        !isPairing && !submittedCode.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        Text(verbatim: LAACopy.pairingAddress)
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        TextField("", text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .modifier(LAAPairingInputStyle())
                            .accessibilityLabel(Text(verbatim: LAACopy.pairingAddress))
                            .accessibilityIdentifier("laa.bridge.address")
                    }
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        Text(verbatim: LAACopy.pairingCode)
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        SecureField("", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .modifier(LAAPairingInputStyle())
                            .accessibilityLabel(Text(verbatim: LAACopy.pairingCode))
                            .accessibilityIdentifier("laa.bridge.code")
                    }
                    Text(verbatim: "Macに表示された接続コードを入力してください。コードは10分間、1回だけ使えます。")
                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    if bridge.status == .paired {
                        Text(verbatim: "接続先を変更した後は、以前の端末登録をMacで失効してください。")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                    if let failure {
                        Text(verbatim: failure.japaneseText)
                            .foregroundStyle(LAAColor.attention)
                            .accessibilityIdentifier("laa.bridge.failure")
                        if failure == .keychain {
                            Text(verbatim: "端末登録が作成されている場合は、Macで今回の登録を失効してください。")
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                    }
                    Button {
                        Task { await pair() }
                    } label: {
                        Group {
                            if isPairing { ProgressView() } else { Text(verbatim: LAACopy.pairingConnect) }
                        }
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LAAColor.filledButtonText)
                    .tint(LAAColor.filledButtonText)
                    .background(LAAColor.filledButton, in: RoundedRectangle(cornerRadius: LAARadius.card))
                    .opacity(canPair ? 1 : 0.5)
                    .disabled(!canPair)
                    .accessibilityIdentifier("laa.bridge.pair")
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, LAASpacing.horizontal)
                .padding(.top, LAASpacing.x6)
                .padding(.bottom, LAASpacing.x8)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(LAAColor.background.ignoresSafeArea())
            .navigationTitle(Text(verbatim: LAACopy.pairingTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(verbatim: LAACopy.close) } } }
            .tint(LAAColor.link)
            .onAppear { address = bridge.address }
        }
    }

    private func pair() async {
        isPairing = true
        failure = nil
        defer { isPairing = false }
        let submitted = submittedCode
        do {
            try await bridge.pair(address: address, code: submitted, name: UIDevice.current.name)
            code = ""
            dismiss()
        } catch let error as LAABridgeError {
            failure = error
            // A spent or rejected code is cleared; one that failed on the way
            // stays, so the user can retry the same 10-minute code.
            if error == .unauthorized || error == .expired { code = "" }
            announce(error)
        } catch is CancellationError {
            return
        } catch {
            failure = .invalidResponse
            announce(.invalidResponse)
        }
    }

    /// VoiceOver stays on Connect when the failure text appears; say it.
    private func announce(_ error: LAABridgeError) {
        AccessibilityNotification.Announcement(error.japaneseText).post()
    }
}

private struct LAAPairingInputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .laaTextStyle(.body)
            .foregroundStyle(LAAColor.text)
            .padding(.horizontal, LAASpacing.x4)
            .frame(minHeight: LAASpacing.minimumRowHeight)
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            .overlay(RoundedRectangle(cornerRadius: LAARadius.card).strokeBorder(LAAColor.separator))
    }
}
#endif
