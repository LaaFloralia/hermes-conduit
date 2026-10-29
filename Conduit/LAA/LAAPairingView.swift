#if LAA_BUILD
import SwiftUI

struct LAAPairingView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var isPairing = false
    @State private var failure: LAABridgeError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $address) { Text(verbatim: "接続先") }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("laa.bridge.address")
                    SecureField(text: $code) { Text(verbatim: "ペアリングコード") }
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("laa.bridge.code")
                } header: {
                    Text(verbatim: "Macに接続")
                } footer: {
                    Text(verbatim: "Macで laa-bridge pair を実行し、表示されたコードを入力してください。コードは10分間、1回だけ使えます。")
                }
                if bridge.status == .paired {
                    Section {
                        Text(verbatim: "接続先を変更した後は、以前の端末登録をMacで失効してください。")
                    }
                }
                if let failure {
                    Section {
                        Text(verbatim: failure.japaneseText).foregroundStyle(LAAColors.plum)
                        if failure == .keychain {
                            Text(verbatim: "端末登録が作成されている場合は、Macで今回の登録を失効してください。")
                        }
                    }
                }
                Section {
                    Button {
                        Task { await pair() }
                    } label: {
                        if isPairing { ProgressView() } else { Text(verbatim: "接続する") }
                    }
                    .disabled(isPairing || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("laa.bridge.pair")
                }
            }
            .navigationTitle(Text(verbatim: "Macとの接続"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(verbatim: "閉じる") } } }
            .tint(LAAColors.teal)
            .onAppear { address = bridge.address }
        }
    }

    private func pair() async {
        isPairing = true
        failure = nil
        defer { isPairing = false; code = "" }
        do {
            try await bridge.pair(address: address, code: code, name: UIDevice.current.name)
            dismiss()
        } catch let error as LAABridgeError {
            failure = error
        } catch is CancellationError {
            return
        } catch {
            failure = .invalidResponse
        }
    }
}
#endif
